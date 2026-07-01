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
require_relative "pairing_service"
require_relative "repo_store"
require_relative "eval_store"
require_relative "routing_config_writer"
require_relative "stats"
require_relative "session_runner"
require_relative "session_store"
require_relative "ws_handler"

module RelayDaemon
  class App < Sinatra::Base
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
    set :session_store, nil   # RelayDaemon::SessionStore; tests inject
    set :stats_db, nil        # RelayDaemon::Db instance; tests and bin/daemon inject
    set :event_bus, RelayDaemon::EventBus.new
    set :ws_upgrader, RelayDaemon::FayeUpgrader
    set :pairing_service, nil # RelayDaemon::PairingService; tests and bin/daemon inject

    # Websockets are handled in middleware (before Sinatra) because the
    # hijacked response must reach the server without post-processing.
    use RelayDaemon::WsRack, self

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

      existing = session_store.active_for_repo(repo["id"])
      if existing
        status 200
        JSON.generate(existing)
      else
        status 201
        JSON.generate(session_store.create(repo: repo, worktrees_dir: settings.relay_config.worktrees_dir))
      end
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
        resume: resume
      )
      status 202
      JSON.generate({ "id" => message["id"] })
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

      test_command = repo["testCommand"]
      test_store = RelayDaemon::SessionTestStore.new(db, session_store)
      if test_command.nil? || test_command.empty?
        test_store.record(session_id: session["id"], tests_passed: nil)
        result = { "testsPassed" => nil }
      else
        log_path = File.join(settings.relay_config.agent_log_dir, "sessions", session["id"], "test.log")
        FileUtils.mkdir_p(File.dirname(log_path))
        pid = Process.spawn("sh", "-c", test_command, out: [log_path, "a"], err: [:child, :out],
                            chdir: File.join(settings.relay_config.worktrees_dir, session["id"]))
        _, test_status = Process.wait2(pid)
        tests_passed = test_status.success?
        test_store.record(session_id: session["id"], tests_passed: tests_passed)
        result = { "testsPassed" => tests_passed }
      end
      if learn_from_outcome && settings.relay_config.routing_config_path
        RelayDaemon::RoutingConfigWriter.new(RelayDaemon::EvalStore.new(db)).write!(settings.relay_config.routing_config_path)
      end
      JSON.generate(result)
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

      git = RelayDaemon::Git.new(repo["path"])
      begin
        git.merge(session["branch"])
      rescue RelayDaemon::Git::GitError => e
        halt 409, JSON.generate({ error: "merge_conflict" }) if e.message == "merge_conflict"

        halt 500, JSON.generate({ error: e.message })
      end

      session_store.update_base_commit(session["id"], git.head_sha)
      settings.event_bus.publish(type: "session.updated", payload: { "sessionId" => session["id"] })
      JSON.generate(T.must(session_store.find(session["id"])))
    end

    not_found do
      content_type :json
      status 404
      JSON.generate({ error: "not found" })
    end
  end
end
