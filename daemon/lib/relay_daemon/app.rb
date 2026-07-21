# typed: false
# frozen_string_literal: true

require "sinatra/base"
require "fileutils"
require "json"
require "securerandom"
require_relative "config"
require_relative "db"
require_relative "event_bus"
require_relative "file_browser"
require_relative "git"
require_relative "llm_call_store"
require_relative "bind_safety"
require_relative "model_catalog"
require_relative "pairing_service"
require_relative "provider_store"
require_relative "push_device_store"
require_relative "push_notifier"
require_relative "repo_store"
require_relative "eval_store"
require_relative "routing_config_writer"
require_relative "stats"
require_relative "session_runner"
require_relative "session_store"
require_relative "ws_handler"

module RelayDaemon
  class App < Sinatra::Base
    MAX_PUSH_DEVICE_BODY_BYTES = 512

    @repo_locks_mutex = Mutex.new
    @repo_locks = {}

    class << self
      def with_repo_lock(repo_id)
        lock = @repo_locks_mutex.synchronize { @repo_locks[repo_id] ||= Mutex.new }
        lock.synchronize { yield }
      end
    end

    set :show_exceptions, false
    # Local REST API — no browser clients, no CSRF surface.
    disable :protection
    # Sinatra 4 host-authorization check; disabled so any client
    # (Tailscale IP, localhost, rack-test) can reach the daemon.
    # Binding to loopback/RFC-1918 is the security boundary.
    set :host_authorization, { permitted_hosts: [] }

    # Evaluated at class load; tests override with custom instances.
    set :relay_config, RelayDaemon::Config.from_env
    set :llm_call_store, nil  # nil = disabled; tests and bin/daemon inject a real one
    set :repo_store, nil      # RelayDaemon::RepoStore; tests inject
    set :provider_store, nil  # RelayDaemon::ProviderStore; tests and bin/daemon inject
    set :session_store, nil   # RelayDaemon::SessionStore; tests inject
    set :stats_db, nil        # RelayDaemon::Db instance; tests and bin/daemon inject
    set :event_bus, RelayDaemon::EventBus.new
    set :ws_upgrader, RelayDaemon::FayeUpgrader
    set :pairing_service, nil # RelayDaemon::PairingService; tests and bin/daemon inject
    set :push_device_store, nil # RelayDaemon::PushDeviceStore; tests and bin/daemon inject
    set :push_notifier, nil # RelayDaemon::PushNotifier; tests and bin/daemon inject

    # Websockets are handled in middleware (before Sinatra) because the
    # hijacked response must reach the server without post-processing.
    use RelayDaemon::WsRack, self

    # ----- Helpers -----

    helpers do
      def publish_session_updated(session)
        settings.event_bus.publish(
          type: "session.updated",
          payload: {
            "sessionId" => session["id"],
            "repoId" => session["repoId"],
            "title" => session["title"],
            "status" => session["status"],
            "lastMessageAt" => session["lastMessageAt"]
          }
        )
      end

      def require_active_session(session)
        halt 409, JSON.generate({ error: "session is not active" }) unless session["status"] == "active"
      end

      def reserve_active_session(session_store, session_id, repo_id)
        RelayDaemon::App.with_repo_lock(repo_id) do
          current = session_store.find(session_id)
          halt 404, JSON.generate({ error: "not found" }) if current.nil?
          require_active_session(current)
          RelayDaemon::SessionRunner.reserve(session_id)
          current
        end
      end

      def valid_session_title?(title)
        title.is_a?(String) && !title.strip.empty? && title.strip.length <= RelayDaemon::SessionStore::MAX_TITLE_LENGTH
      end

      # Redacted, client-facing shape for a provider hash (see
      # RelayDaemon::ProviderStore#all / #create): api_key is never
      # serialized to clients, only whether one is set.
      def provider_public(provider)
        {
          "name" => provider.fetch("name"),
          "baseUrl" => provider.fetch("baseUrl"),
          "hasApiKey" => !provider["apiKey"].nil?,
          "models" => provider.fetch("models")
        }
      end

      # Regenerates the routing config file (tiers reordered by learned pass
      # rates, plus the providers section) so the router's hot-reload picks
      # up provider or test-outcome changes immediately. No-op unless both a
      # routing config path and a database are configured.
      def write_routing_config!
        path = settings.relay_config.routing_config_path
        return if path.nil?

        db = settings.stats_db
        return if db.nil?

        RelayDaemon::RoutingConfigWriter.new(
          RelayDaemon::EvalStore.new(db),
          provider_store: settings.provider_store
        ).write!(path)
      end
    end

    # ----- Auth -----

    before do
      next if request.path_info == "/healthz"
      next if request.path_info.start_with?("/pair/")

      static_token = settings.relay_config.daemon_token
      pairing      = settings.pairing_service
      has_static   = !static_token.nil? && !static_token.empty?

      if !has_static && pairing.nil?
        content_type :json
        halt 500, JSON.generate({ error: "daemon token not configured" })
      end

      auth_header = env["HTTP_AUTHORIZATION"] || ""
      bearer = auth_header.sub(/\ABearer\s+/, "")

      static_ok = has_static && Rack::Utils.secure_compare(static_token, bearer)
      paired_ok = !pairing.nil? && pairing.token_valid?(bearer)
      unless static_ok || paired_ok
        content_type :json
        halt 401, JSON.generate({ error: "unauthorized" })
      end
    end

    # ----- Routes -----

    get "/healthz" do
      content_type :json
      JSON.generate({ status: "ok", version: "0.1.0" })
    end

    get "/whoami" do
      content_type :json
      JSON.generate({ ok: true })
    end

    # ----- Pairing -----

    post "/pair/start" do
      content_type :json

      unless RelayDaemon::BindSafety.safe?(request.ip)
        halt 403, JSON.generate({ error: "pairing only allowed from private networks" })
      end

      svc = settings.pairing_service
      halt 503, JSON.generate({ error: "pairing not configured" }) if svc.nil?

      cfg = settings.relay_config
      if RelayDaemon::BindSafety.loopback?(cfg.host)
        halt 503, JSON.generate({
          error: "daemon is bound to loopback only; set RELAY_DAEMON_HOST to a Tailscale or LAN address and restart"
        })
      end

      code = svc.start_pairing
      JSON.generate({
        "qrPayload" => {
          "url" => "http://#{cfg.host}:#{cfg.port}",
          "pairingCode" => code
        }
      })
    end

    post "/pair/claim" do
      content_type :json

      svc = settings.pairing_service
      halt 503, JSON.generate({ error: "pairing not configured" }) if svc.nil?

      body_str = request.body.read
      data = begin
        JSON.parse(body_str)
      rescue JSON::ParserError
        halt 400, JSON.generate({ error: "invalid JSON" })
      end
      halt 400, JSON.generate({ error: "body must be a JSON object" }) unless data.is_a?(Hash)

      token = svc.claim(data["pairingCode"].to_s)
      halt 401, JSON.generate({ error: "invalid pairing code" }) if token.nil?

      JSON.generate({ "authToken" => token })
    end

    # ----- Repos -----

    get "/fs/entries" do
      content_type :json

      begin
        JSON.generate(RelayDaemon::FileBrowser.new.list(path: params[:path].to_s))
      rescue ArgumentError => e
        halt 422, JSON.generate({ error: e.message })
      end
    end

    get "/repos" do
      content_type :json
      store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if store.nil?
      JSON.generate(store.all)
    end

    post "/repos" do
      content_type :json

      body_str = request.body.read
      data = begin
        JSON.parse(body_str)
      rescue JSON::ParserError
        halt 400, JSON.generate({ error: "invalid JSON" })
      end

      unless data.is_a?(Hash) && data["path"].is_a?(String)
        halt 422, JSON.generate({ error: "path is required" })
      end

      store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if store.nil?

      begin
        repo = store.create(path: data["path"], test_command: data["testCommand"])
        status 201
        JSON.generate(repo)
      rescue ArgumentError => e
        halt 422, JSON.generate({ error: e.message })
      rescue SQLite3::ConstraintException
        halt 409, JSON.generate({ error: "path already registered" })
      end
    end

    # ----- Stats -----

    get "/stats" do
      content_type :json

      range = params[:range] || "30d"
      db = settings.stats_db
      halt 503, JSON.generate({ error: "database not configured" }) if db.nil?

      begin
        result = RelayDaemon::Stats.new(db).compute(range: range)
        JSON.generate(result)
      rescue ArgumentError => e
        halt 422, JSON.generate({ error: e.message })
      end
    end

    # Per-model test-verified outcomes — the eval-dataset rollup that drives
    # outcome-verified routing and the savings dashboard's pass-rate.
    get "/eval/model-outcomes" do
      content_type :json
      db = settings.stats_db
      halt 503, JSON.generate({ error: "database not configured" }) if db.nil?
      JSON.generate({ modelOutcomes: RelayDaemon::EvalStore.new(db).model_outcomes })
    end

    # ----- Models -----

    # Live routing tiers (from RoutingConfigWriter's output, or the built-in
    # default) so clients like the iOS model picker don't hardcode model ids.
    get "/models" do
      content_type :json
      catalog = RelayDaemon::ModelCatalog.new(
        settings.relay_config.routing_config_path,
        provider_store: settings.provider_store
      ).catalog
      JSON.generate(catalog)
    end

    # ----- Providers -----

    get "/providers" do
      content_type :json
      store = settings.provider_store
      halt 503, JSON.generate({ error: "provider store not configured" }) if store.nil?

      JSON.generate(store.all.map { |p| provider_public(p) })
    end

    post "/providers" do
      content_type :json

      body_str = request.body.read
      data = begin
        JSON.parse(body_str)
      rescue JSON::ParserError
        halt 400, JSON.generate({ error: "invalid JSON" })
      end

      unless data.is_a?(Hash) && data["name"].is_a?(String) && data["baseUrl"].is_a?(String)
        halt 422, JSON.generate({ error: "name and baseUrl are required" })
      end

      store = settings.provider_store
      halt 503, JSON.generate({ error: "provider store not configured" }) if store.nil?

      models = data["models"].is_a?(Array) ? data["models"].map(&:to_s) : []
      api_key = data["apiKey"].is_a?(String) ? data["apiKey"] : nil

      begin
        provider = store.create(name: data["name"], base_url: data["baseUrl"], api_key: api_key, models: models)
      rescue ArgumentError => e
        halt 422, JSON.generate({ error: e.message })
      rescue SQLite3::ConstraintException
        halt 409, JSON.generate({ error: "provider already registered" })
      end

      write_routing_config!
      status 201
      JSON.generate(provider_public(provider))
    end

    delete "/providers/:name" do
      content_type :json
      store = settings.provider_store
      halt 503, JSON.generate({ error: "provider store not configured" }) if store.nil?

      halt 404, JSON.generate({ error: "not found" }) unless store.delete(params[:name])

      write_routing_config!
      status 204
      ""
    end

    # ----- Push devices -----

    post "/push/devices" do
      content_type :json

      body_str = request.body.read(MAX_PUSH_DEVICE_BODY_BYTES + 1)
      if body_str.bytesize > MAX_PUSH_DEVICE_BODY_BYTES
        halt 413, JSON.generate({ error: "request body too large" })
      end
      data = begin
        JSON.parse(body_str)
      rescue JSON::ParserError
        halt 400, JSON.generate({ error: "invalid JSON" })
      end

      unless data.is_a?(Hash) &&
             data["deviceToken"].is_a?(String) &&
             RelayDaemon::PushDeviceStore.valid_device_token?(data["deviceToken"])
        halt 422, JSON.generate({ error: "deviceToken must be 16..128 even-length hex characters" })
      end

      store = settings.push_device_store
      halt 503, JSON.generate({ error: "push device store not configured" }) if store.nil?

      existing = store.find(data["deviceToken"])
      device = store.create(device_token: data["deviceToken"])

      status existing.nil? ? 201 : 200
      JSON.generate(device)
    end

    delete "/push/devices/:token" do
      content_type :json
      unless RelayDaemon::PushDeviceStore.valid_device_token?(params[:token])
        halt 422, JSON.generate({ error: "deviceToken must be 16..128 even-length hex characters" })
      end
      store = settings.push_device_store
      halt 503, JSON.generate({ error: "push device store not configured" }) if store.nil?
      halt 404, JSON.generate({ error: "not found" }) unless store.delete(params[:token])

      status 204
      ""
    end

    # ----- Internal call-log ingestion -----

    post "/internal/llm-calls" do
      content_type :json

      body_str = request.body.read
      data = begin
        JSON.parse(body_str)
      rescue JSON::ParserError
        halt 400, JSON.generate({ error: "invalid JSON" })
      end

      unless data.is_a?(Hash)
        halt 400, JSON.generate({ error: "body must be a JSON object" })
      end

      store = settings.llm_call_store
      halt 503, JSON.generate({ error: "call log store not configured" }) if store.nil?

      begin
        id = store.insert(data)
        status 201
        JSON.generate({ id: id })
      rescue ArgumentError => e
        halt 422, JSON.generate({ error: e.message })
      end
    end

    # ----- Chat sessions -----

    get "/repos/:id/sessions" do
      content_type :json
      repo_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if repo_store.nil?
      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?

      repo_id = Integer(params[:id], 10) rescue nil
      halt 422, JSON.generate({ error: "repo id must be an integer" }) if repo_id.nil?
      halt 404, JSON.generate({ error: "repo not found" }) if repo_store.find(repo_id).nil?

      JSON.generate(session_store.list_for_repo(repo_id))
    end

    post "/repos/:id/sessions" do
      content_type :json
      repo_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if repo_store.nil?
      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?

      repo_id = Integer(params[:id], 10) rescue nil
      halt 422, JSON.generate({ error: "repo id must be an integer" }) if repo_id.nil?
      repo = repo_store.find(repo_id)
      halt 404, JSON.generate({ error: "repo not found" }) if repo.nil?

      body_str = request.body.read
      data = if body_str.empty?
               {}
             else
               begin
                 JSON.parse(body_str)
               rescue JSON::ParserError
                 halt 400, JSON.generate({ error: "invalid JSON" })
               end
             end
      unless data.is_a?(Hash)
        halt 422, JSON.generate({ error: "body must be a JSON object" })
      end
      title = data["title"]
      unless title.nil? || valid_session_title?(title)
        halt 422, JSON.generate({ error: "title must be a non-empty string of at most 200 characters" })
      end

      session = RelayDaemon::App.with_repo_lock(repo["id"]) do
        created = session_store.create(repo: repo, worktrees_dir: settings.relay_config.worktrees_dir)
        created = session_store.rename(created["id"], title) unless title.nil?
        created
      end
      status 201
      publish_session_updated(session)
      JSON.generate(session)
    end

    post "/sessions" do
      content_type :json

      body_str = request.body.read
      data = begin
        JSON.parse(body_str)
      rescue JSON::ParserError
        halt 400, JSON.generate({ error: "invalid JSON" })
      end

      unless data.is_a?(Hash) && data["repoId"].is_a?(Integer)
        halt 422, JSON.generate({ error: "repoId is required" })
      end

      repo_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if repo_store.nil?
      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?

      repo = repo_store.find(data["repoId"])
      halt 422, JSON.generate({ error: "repo not found" }) if repo.nil?

      session, created = RelayDaemon::App.with_repo_lock(repo["id"]) do
        current = session_store.most_recent_active_for_repo(repo["id"])
        current ? [current, false] : [session_store.create(repo: repo, worktrees_dir: settings.relay_config.worktrees_dir), true]
      end
      status(created ? 201 : 200)
      publish_session_updated(session) if created
      JSON.generate(session)
    end

    get "/sessions/:id" do
      content_type :json
      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?
      session = session_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if session.nil?
      JSON.generate(session)
    end

    patch "/sessions/:id" do
      content_type :json
      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?
      session = session_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if session.nil?
      data = begin
        JSON.parse(request.body.read)
      rescue JSON::ParserError
        halt 400, JSON.generate({ error: "invalid JSON" })
      end
      unless data.is_a?(Hash) && data.key?("title") && valid_session_title?(data["title"])
        halt 422, JSON.generate({ error: "title must be a non-empty string of at most 200 characters" })
      end

      renamed = RelayDaemon::App.with_repo_lock(session["repoId"]) do
        current = session_store.find(session["id"])
        halt 404, JSON.generate({ error: "not found" }) if current.nil?
        require_active_session(current)
        session_store.rename(current["id"], data["title"])
      end
      halt 404, JSON.generate({ error: "not found" }) if renamed.nil?
      publish_session_updated(renamed)
      JSON.generate(renamed)
    end

    get "/sessions/:id/messages" do
      content_type :json

      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?

      session = session_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if session.nil?

      db = settings.stats_db
      halt 503, JSON.generate({ error: "database not configured" }) if db.nil?

      JSON.generate(RelayDaemon::MessageStore.new(db, session_store).list_for_session(params[:id]))
    end

    post "/sessions/:id/messages" do
      content_type :json

      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?
      db = settings.stats_db
      halt 503, JSON.generate({ error: "database not configured" }) if db.nil?

      body_str = request.body.read
      data = begin
        JSON.parse(body_str)
      rescue JSON::ParserError
        halt 400, JSON.generate({ error: "invalid JSON" })
      end

      content = data["content"] if data.is_a?(Hash)
      model_override = data["modelOverride"] if data.is_a?(Hash)
      unless data.is_a?(Hash) &&
             content.is_a?(String) && !content.empty? &&
             (model_override.nil? || (model_override.is_a?(String) && !model_override.empty?))
        halt 422, JSON.generate({ error: "content (non-empty string) and optional modelOverride required" })
      end

      session = session_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if session.nil?

      reserved = false
      begin
        session = reserve_active_session(session_store, session["id"], session["repoId"])
        reserved = true
        agent_command = settings.relay_config.agent_command
        halt 503, JSON.generate({ error: "agent command not configured" }) if agent_command.nil?

        message_store = RelayDaemon::MessageStore.new(db, session_store)
        resume = !message_store.list_for_session(session["id"]).empty?
        run_id = SecureRandom.uuid
        message = message_store.append(
          session_id: session["id"],
          role: "user",
          content: content,
          agent_run_id: run_id
        )
        settings.event_bus.publish(
          type: "message.created",
          payload: { "sessionId" => session["id"], "message" => message }
        )
        publish_session_updated(T.must(session_store.find(session["id"])))

        agent_argv = RelayDaemon::SessionRunner.build_argv(agent_command, content, session_id: session["id"], resume: resume)
        agent_argv += ["--model", model_override] if model_override

        RelayDaemon::SessionRunner.run_async(
          session_id: session["id"],
          content: content,
          worktree_path: File.join(settings.relay_config.worktrees_dir, session["id"]),
          sessions_log_dir: File.join(settings.relay_config.agent_log_dir, "sessions"),
          agent_command: agent_argv,
          db_path: settings.relay_config.db_path,
          event_bus: settings.event_bus,
          router_base_url: settings.relay_config.router_base_url,
          run_id: run_id,
          append_user: false,
          resume: resume,
          push_notifier: settings.push_notifier,
          reserved: true
        )
        reserved = false
        status 202
        JSON.generate({ "id" => message["id"] })
      ensure
        RelayDaemon::SessionRunner.release(session["id"]) if reserved
      end
    end

    get "/sessions/:id/diff" do
      content_type :json

      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?
      session = session_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if session.nil?

      git = RelayDaemon::Git.new(File.join(settings.relay_config.worktrees_dir, session["id"]))
      JSON.generate(git.diff_files(session["baseCommit"].to_s))
    end

    post "/sessions/:id/test" do
      content_type :json

      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?
      repo_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if repo_store.nil?
      db = settings.stats_db
      halt 503, JSON.generate({ error: "database not configured" }) if db.nil?
      session = session_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if session.nil?
      repo = repo_store.find(session["repoId"])
      halt 422, JSON.generate({ error: "repo not found" }) if repo.nil?

      body_str = request.body.read
      data = if body_str.empty?
               {}
             else
               begin
                 JSON.parse(body_str)
               rescue JSON::ParserError
                 halt 400, JSON.generate({ error: "invalid JSON" })
               end
             end
      unless data.is_a?(Hash)
        halt 400, JSON.generate({ error: "body must be a JSON object" })
      end
      learn_from_outcome = data.key?("learnFromOutcome") ? data["learnFromOutcome"] : true
      unless learn_from_outcome == true || learn_from_outcome == false
        halt 422, JSON.generate({ error: "learnFromOutcome must be boolean" })
      end
      auto_retry = data.key?("autoRetry") ? data["autoRetry"] : false
      unless auto_retry == true || auto_retry == false
        halt 422, JSON.generate({ error: "autoRetry must be boolean" })
      end

      reserved = false
      begin
        session = reserve_active_session(session_store, session["id"], session["repoId"])
        reserved = true
        test_command = repo["testCommand"]
        test_store = RelayDaemon::SessionTestStore.new(db, session_store)
        if test_command.nil? || test_command.empty?
          test_store.record(session_id: session["id"], tests_passed: nil)
          settings.push_notifier&.notify(RelayDaemon::PushNotifier::TESTS_FINISHED)
          result = { "testsPassed" => nil }
        else
          log_path = File.join(settings.relay_config.agent_log_dir, "sessions", session["id"], "test.log")
          FileUtils.mkdir_p(File.dirname(log_path))
          pid = Process.spawn("sh", "-c", test_command, out: [log_path, "a"], err: [:child, :out],
                              chdir: File.join(settings.relay_config.worktrees_dir, session["id"]))
          _, test_status = Process.wait2(pid)
          tests_passed = test_status.success?
          test_store.record(session_id: session["id"], tests_passed: tests_passed)
          settings.push_notifier&.notify(RelayDaemon::PushNotifier::TESTS_FINISHED)
          result = { "testsPassed" => tests_passed }

          if tests_passed == false && auto_retry
            agent_command = settings.relay_config.agent_command
            halt 503, JSON.generate({ error: "agent command not configured" }) if agent_command.nil?

            tail_output = File.readlines(log_path).last(50).join
            retry_content = "Tests failed:\n#{tail_output}Fix and keep changes minimal."

            message_store = RelayDaemon::MessageStore.new(db, session_store)
            run_id = SecureRandom.uuid
            message = message_store.append(
              session_id: session["id"],
              role: "user",
              content: retry_content,
              agent_run_id: run_id
            )
            settings.event_bus.publish(
              type: "message.created",
              payload: { "sessionId" => session["id"], "message" => message }
            )
            publish_session_updated(T.must(session_store.find(session["id"])))

            agent_argv = RelayDaemon::SessionRunner.build_argv(
              agent_command, retry_content, session_id: session["id"], resume: true
            )

            RelayDaemon::SessionRunner.run_async(
              session_id: session["id"],
              content: retry_content,
              worktree_path: File.join(settings.relay_config.worktrees_dir, session["id"]),
              sessions_log_dir: File.join(settings.relay_config.agent_log_dir, "sessions"),
              agent_command: agent_argv,
              db_path: settings.relay_config.db_path,
              event_bus: settings.event_bus,
              router_base_url: settings.relay_config.router_base_url,
              run_id: run_id,
              append_user: false,
              resume: true,
              escalated: true,
              push_notifier: settings.push_notifier,
              reserved: true
            )
            reserved = false
          end
        end
        write_routing_config! if learn_from_outcome
        JSON.generate(result)
      ensure
        RelayDaemon::SessionRunner.release(session["id"]) if reserved
      end
    end

    post "/sessions/:id/approve" do
      content_type :json

      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?
      repo_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if repo_store.nil?
      session = session_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if session.nil?
      repo = repo_store.find(session["repoId"])
      halt 422, JSON.generate({ error: "repo not found" }) if repo.nil?

      RelayDaemon::App.with_repo_lock(repo["id"]) do
        session = session_store.find(params[:id])
        halt 404, JSON.generate({ error: "not found" }) if session.nil?
        require_active_session(session)
        git = RelayDaemon::Git.new(repo["path"])
        begin
          git.merge(session["branch"])
        rescue RelayDaemon::Git::GitError => e
          halt 409, JSON.generate({ error: "merge_conflict" }) if e.message == "merge_conflict"

          halt 500, JSON.generate({ error: e.message })
        end

        session_store.update_base_commit(session["id"], git.head_sha)
      end
      updated = T.must(session_store.find(session["id"]))
      publish_session_updated(updated)
      JSON.generate(updated)
    end

    post "/sessions/:id/discard" do
      content_type :json

      session_store = settings.session_store
      halt 503, JSON.generate({ error: "session store not configured" }) if session_store.nil?
      repo_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if repo_store.nil?
      session = session_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if session.nil?
      repo = repo_store.find(session["repoId"])
      halt 422, JSON.generate({ error: "repo not found" }) if repo.nil?

      discarded = RelayDaemon::App.with_repo_lock(repo["id"]) do
        session = session_store.find(params[:id])
        halt 404, JSON.generate({ error: "not found" }) if session.nil?
        halt 409, JSON.generate({ error: "already discarded" }) if session["status"] == "discarded"
        if RelayDaemon::SessionRunner.running?(session["id"])
          halt 409, JSON.generate({ error: "agent run in progress" })
        end
        git = RelayDaemon::Git.new(repo["path"])
        git.worktree_remove(File.join(settings.relay_config.worktrees_dir, session["id"]))
        git.branch_delete(session["branch"])
        session_store.discard(session["id"])
      end
      publish_session_updated(T.must(discarded))
      JSON.generate(T.must(discarded))
    end

    not_found do
      content_type :json
      status 404
      JSON.generate({ error: "not found" })
    end
  end
end
