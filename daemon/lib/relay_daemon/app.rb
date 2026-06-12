# typed: false
# frozen_string_literal: true

require "sinatra/base"
require "json"
require "securerandom"
require_relative "config"
require_relative "db"
require_relative "event_bus"
require_relative "git"
require_relative "llm_call_store"
require_relative "pairing_service"
require_relative "repo_store"
require_relative "stats"
require_relative "task_runner"
require_relative "task_store"
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
    set :task_store, nil      # RelayDaemon::TaskStore; tests inject
    set :stats_db, nil        # RelayDaemon::Db instance; tests and bin/daemon inject
    set :event_bus, RelayDaemon::EventBus.new
    set :ws_upgrader, RelayDaemon::FayeUpgrader
    set :pairing_service, nil # RelayDaemon::PairingService; tests and bin/daemon inject

    # ----- Auth -----

    before do
      next if request.path_info == "/healthz"
      next if request.path_info.start_with?("/pair/")
      # /ws authenticates via its ?token= query param (browsers cannot set
      # Authorization headers on websocket connections).
      next if request.path_info == "/ws"

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

      unless ["127.0.0.1", "::1"].include?(request.ip)
        halt 403, JSON.generate({ error: "pairing only allowed from localhost" })
      end

      svc = settings.pairing_service
      halt 503, JSON.generate({ error: "pairing not configured" }) if svc.nil?

      cfg  = settings.relay_config
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

    # ----- WebSocket events -----

    get "/ws" do
      upgrader = settings.ws_upgrader
      unless upgrader.upgrade?(request.env)
        content_type :json
        halt 400, JSON.generate({ error: "websocket upgrade required" })
      end

      ws = upgrader.upgrade(request.env)
      RelayDaemon::WsHandler.attach(
        ws,
        token: params[:token],
        expected_token: settings.relay_config.daemon_token,
        bus: settings.event_bus
      )
      ws.rack_response
    end

    # ----- Repos -----

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

    # ----- Tasks -----

    post "/tasks" do
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

      repo_id      = data["repoId"]
      prompt       = data["prompt"]
      quality_dial = data["qualityDial"]

      unless repo_id.is_a?(Integer) &&
             prompt.is_a?(String) && !prompt.empty? &&
             quality_dial.is_a?(Integer) && quality_dial >= 0 && quality_dial <= 10
        halt 422, JSON.generate({ error: "repoId (integer), prompt (non-empty string), qualityDial (0–10 integer) required" })
      end

      repo_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if repo_store.nil?

      t_store = settings.task_store
      halt 503, JSON.generate({ error: "task store not configured" }) if t_store.nil?

      agent_command = settings.relay_config.agent_command
      halt 503, JSON.generate({ error: "agent command not configured" }) if agent_command.nil?

      repo = repo_store.find(repo_id)
      halt 422, JSON.generate({ error: "repo not found" }) if repo.nil?

      cfg         = settings.relay_config
      git         = RelayDaemon::Git.new(repo["path"])
      base_commit = git.head_sha
      base_branch = git.current_branch

      task_id      = SecureRandom.uuid
      branch       = "relay/#{task_id}"
      worktree_path = File.join(cfg.worktrees_dir, task_id)
      log_path      = File.join(cfg.agent_log_dir, task_id, "agent.log")

      task = t_store.create(
        id:           task_id,
        repo_id:      repo_id,
        prompt:       prompt,
        quality_dial: quality_dial,
        branch:       branch,
        base_commit:  base_commit,
        base_branch:  base_branch
      )

      git.worktree_add(worktree_path, branch: branch)
      agent_argv = RelayDaemon::TaskRunner.build_argv(agent_command, prompt)
      RelayDaemon::TaskRunner.run_async(
        task_id:      task_id,
        worktree_path: worktree_path,
        log_path:     log_path,
        agent_argv:   agent_argv,
        db_path:      cfg.db_path,
        event_bus:    settings.event_bus,
        test_command: repo["testCommand"],
        agent_env:    { "RELAY_TASK_ID" => task_id }
      )

      status 201
      JSON.generate(task)
    end

    get "/tasks/:id" do
      content_type :json

      t_store = settings.task_store
      halt 503, JSON.generate({ error: "task store not configured" }) if t_store.nil?

      task = t_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if task.nil?

      JSON.generate(task)
    end

    post "/tasks/:id/approve" do
      content_type :json

      t_store = settings.task_store
      halt 503, JSON.generate({ error: "task store not configured" }) if t_store.nil?
      r_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if r_store.nil?

      task = t_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if task.nil?
      unless task["status"] == "needs_review"
        halt 409, JSON.generate({ error: "task is #{task["status"]}, not needs_review" })
      end

      repo = r_store.find(task["repoId"])
      git  = RelayDaemon::Git.new(repo["path"])

      # The merge lands on whatever branch is checked out; refuse if the
      # user has since switched away from the branch the task was based on.
      unless git.current_branch == task["baseBranch"]
        halt 409, JSON.generate({ error: "base branch #{task["baseBranch"]} is not checked out" })
      end

      begin
        git.merge(task["branch"])
      rescue RelayDaemon::Git::GitError => e
        halt 409, JSON.generate({ error: "merge_conflict" }) if e.message == "merge_conflict"

        halt 500, JSON.generate({ error: e.message })
      end

      worktree_path = File.join(settings.relay_config.worktrees_dir, task["id"])
      git.worktree_remove(worktree_path)
      t_store.update_status(task["id"], "approved")
      settings.event_bus.publish(type: "task.finished", task_id: task["id"],
                                 payload: { "status" => "approved" })
      settings.event_bus.publish(type: "stats.updated", task_id: task["id"])

      JSON.generate(T.must(t_store.find(task["id"])))
    end

    post "/tasks/:id/reject" do
      content_type :json

      t_store = settings.task_store
      halt 503, JSON.generate({ error: "task store not configured" }) if t_store.nil?
      r_store = settings.repo_store
      halt 503, JSON.generate({ error: "repo store not configured" }) if r_store.nil?

      task = t_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if task.nil?
      unless %w[needs_review failed].include?(task["status"])
        halt 409, JSON.generate({ error: "task is #{task["status"]}, not needs_review/failed" })
      end

      repo = r_store.find(task["repoId"])
      git  = RelayDaemon::Git.new(repo["path"])

      worktree_path = File.join(settings.relay_config.worktrees_dir, task["id"])
      git.worktree_remove(worktree_path)
      git.delete_branch(task["branch"])
      t_store.update_status(task["id"], "rejected")
      settings.event_bus.publish(type: "task.finished", task_id: task["id"],
                                 payload: { "status" => "rejected" })
      settings.event_bus.publish(type: "stats.updated", task_id: task["id"])

      JSON.generate(T.must(t_store.find(task["id"])))
    end

    get "/tasks/:id/diff" do
      content_type :json

      t_store = settings.task_store
      halt 503, JSON.generate({ error: "task store not configured" }) if t_store.nil?

      task = t_store.find(params[:id])
      halt 404, JSON.generate({ error: "not found" }) if task.nil?

      worktree_path = File.join(settings.relay_config.worktrees_dir, task["id"])
      git   = RelayDaemon::Git.new(worktree_path)
      diffs = git.diff_files(task["baseCommit"].to_s)

      JSON.generate(diffs)
    end

    not_found do
      content_type :json
      status 404
      JSON.generate({ error: "not found" })
    end
  end
end
