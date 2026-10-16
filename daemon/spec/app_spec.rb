# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/approval_settings_store"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/llm_call_store"
require "relay_daemon/permission_request_registry"
require "relay_daemon/repo_store"
require "relay_daemon/session_store"
require "timeout"
require "tmpdir"

RSpec.describe RelayDaemon::App do
  include Rack::Test::Methods

  def app
    described_class
  end

  let(:token) { "test-token-abc123" }
  let(:config) do
    RelayDaemon::Config.new(
      daemon_token: token,
      host: "127.0.0.1",
      port: 7777,
      db_path: "/tmp/relay_test.db"
    )
  end

  let(:internal_token) { "router-internal-token" }

  before do
    described_class.set(:relay_config, config)
  end

  # ----- Health (no auth required) -----

  describe "GET /healthz" do
    before { get "/healthz" }

    it "returns 200 without a token" do
      expect(last_response.status).to eq(200)
    end

    it "returns JSON content type" do
      expect(last_response.content_type).to include("application/json")
    end

    it "returns status, version, and disabled optional capabilities" do
      body = JSON.parse(last_response.body)
      expect(body).to eq(
        {
          "status" => "ok",
          "version" => "0.1.0",
          "capabilities" => {
            "routingLearning" => false,
            "pushNotifications" => false,
            "routingSummaries" => true
          }
        }
      )
    end

    context "when optional services are configured" do
      let(:config) do
        RelayDaemon::Config.new(
          daemon_token: token,
          internal_token: internal_token,
          host: "127.0.0.1",
          port: 7777,
          db_path: "/tmp/relay_test.db",
          routing_config_path: "/tmp/routing.json",
          push_relay_url: "https://push.example.test/push",
          push_relay_token: "push-token"
        )
      end

      it "reports enabled routing learning and push notifications" do
        body = JSON.parse(last_response.body)
        expect(body.fetch("capabilities")).to eq(
          "routingLearning" => true,
          "pushNotifications" => true,
          "routingSummaries" => true
        )
      end
    end
  end

  describe "unknown path" do
    before { get "/no-such-route", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" } }

    it "returns 404" do
      expect(last_response.status).to eq(404)
    end

    it "returns JSON error body" do
      body = JSON.parse(last_response.body)
      expect(body).to eq({ "error" => "not found" })
    end
  end

  # ----- Auth behaviour -----

  describe "GET /whoami (protected route)" do
    context "without any Authorization header" do
      before { get "/whoami" }

      it "returns 401" do
        expect(last_response.status).to eq(401)
      end

      it "returns JSON unauthorized error" do
        body = JSON.parse(last_response.body)
        expect(body).to eq({ "error" => "unauthorized" })
      end
    end

    context "with wrong token" do
      before { get "/whoami", {}, { "HTTP_AUTHORIZATION" => "Bearer wrong-token" } }

      it "returns 401" do
        expect(last_response.status).to eq(401)
      end
    end

    context "with correct token" do
      before { get "/whoami", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" } }

      it "returns 200" do
        expect(last_response.status).to eq(200)
      end

      it "returns ok body" do
        body = JSON.parse(last_response.body)
        expect(body).to eq({ "ok" => true })
      end
    end

    context "when RELAY_DAEMON_TOKEN is not configured" do
      let(:config) do
        RelayDaemon::Config.new(
          daemon_token: nil,
          host: "127.0.0.1",
          port: 7777,
          db_path: "/tmp/relay_test.db"
        )
      end

      before { get "/whoami" }

      it "returns 500" do
        expect(last_response.status).to eq(500)
      end

      it "returns JSON error body" do
        body = JSON.parse(last_response.body)
        expect(body).to eq({ "error" => "daemon token not configured" })
      end
    end
  end

  # /pair/* paths are exempt from auth
  describe "GET /pair/anything" do
    before { get "/pair/anything" }

    it "does not return 401 even without a token" do
      expect(last_response.status).not_to eq(401)
    end
  end

  # ----- POST /internal/llm-calls -----

  describe "POST /internal/llm-calls" do
    let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
    let(:db)      { RelayDaemon::Db.new(db_path) }
    let(:store)   { RelayDaemon::LlmCallStore.new(db) }

    let(:valid_body) do
      {
        runId: "run-123",
        requestedModel: "deepseek-flash",
        routeTarget: "openrouter-auto",
        routedModel: "openai/gpt-5.5",
        provider: "openrouter",
        tier: 1,
        promptTokens: 100,
        completionTokens: 50,
        costUsd: 0.001,
        frontierCostUsd: 0.005,
        latencyMs: 300,
        escalationReason: nil,
        status: "success",
        errorMessage: nil,
        createdAt: "2026-06-12T00:00:00Z"
      }
    end

    before do
      described_class.set(:llm_call_store, store)
    end

    after { db.connection.close }

    def post_call(body, headers = {})
      post "/internal/llm-calls",
           body.to_json,
           { "CONTENT_TYPE" => "application/json",
             "HTTP_AUTHORIZATION" => "Bearer #{token}" }.merge(headers)
    end

    context "with a dedicated internal token configured" do
      let(:config) do
        RelayDaemon::Config.new(
          daemon_token: token,
          internal_token: internal_token,
          host: "127.0.0.1",
          port: 7777,
          db_path: "/tmp/relay_test.db"
        )
      end

      it "accepts the internal token and rejects the client token" do
        post_call(valid_body, "HTTP_AUTHORIZATION" => "Bearer #{internal_token}")
        expect(last_response.status).to eq(201)

        post_call(valid_body)
        expect(last_response.status).to eq(401)
      end
    end

    context "with a valid record" do
      before { post_call(valid_body) }

      it "returns 201" do
        expect(last_response.status).to eq(201)
      end

      it "returns the inserted row id" do
        body = JSON.parse(last_response.body)
        expect(body["id"]).to be_a(Integer)
        expect(body["id"]).to be > 0
      end

      it "persists the record in llm_calls" do
        rows = db.connection.execute("SELECT * FROM llm_calls")
        expect(rows.length).to eq(1)
        expect(rows.first["requested_model"]).to eq("deepseek-flash")
      end

      it "persists the provider column" do
        row = db.connection.execute("SELECT provider FROM llm_calls ORDER BY id DESC LIMIT 1").first
        expect(row["provider"]).to eq("openrouter")
      end

      it "persists session attribution and leaves historical task attribution empty" do
        repo = RelayDaemon::RepoStore.new(db).create(path: make_git_dir)
        session = RelayDaemon::SessionStore.new(db).create(repo: repo, worktrees_dir: Dir.mktmpdir)

        post_call(valid_body.merge(sessionId: session["id"]))

        row = db.connection.execute(
          "SELECT task_id, session_id, run_id, route_target, routed_model FROM llm_calls ORDER BY id DESC LIMIT 1"
        ).first
        expect(row["task_id"]).to be_nil
        expect(row["session_id"]).to eq(session["id"])
        expect(row["run_id"]).to eq("run-123")
        expect(row["route_target"]).to eq("openrouter-auto")
        expect(row["routed_model"]).to eq("openai/gpt-5.5")
      end
    end

    context "with a custom provider" do
      it "persists the custom provider name and exposes it via eval_dataset" do
        repo = RelayDaemon::RepoStore.new(db).create(path: make_git_dir)
        session = RelayDaemon::SessionStore.new(db).create(repo: repo, worktrees_dir: Dir.mktmpdir)

        post_call(valid_body.merge(sessionId: session["id"], provider: "myvllm", routedModel: "myvllm::qwen3-32b"))
        expect(last_response.status).to eq(201)

        row = db.connection.execute("SELECT provider, routed_model FROM llm_calls ORDER BY id DESC LIMIT 1").first
        expect(row["provider"]).to eq("myvllm")
        expect(row["routed_model"]).to eq("myvllm::qwen3-32b")

        view_row = db.connection.execute(
          "SELECT provider FROM eval_dataset WHERE session_id = ?", [session["id"]]
        ).first
        expect(view_row["provider"]).to eq("myvllm")
      end
    end

    context "without a provider (backward compatibility with older routers)" do
      it "persists a null provider" do
        post_call(valid_body.except(:provider))
        expect(last_response.status).to eq(201)

        row = db.connection.execute("SELECT provider FROM llm_calls ORDER BY id DESC LIMIT 1").first
        expect(row["provider"]).to be_nil
      end

      it "uses routedModel as the route target for an older payload" do
        post_call(valid_body.except(:routeTarget, :runId))
        expect(last_response.status).to eq(201)

        row = db.connection.execute(
          "SELECT run_id, route_target FROM llm_calls ORDER BY id DESC LIMIT 1"
        ).first
        expect(row["run_id"]).to be_nil
        expect(row["route_target"]).to eq("openai/gpt-5.5")
      end
    end

    context "with a missing required field" do
      before { post_call(valid_body.except(:status)) }

      it "returns 422" do
        expect(last_response.status).to eq(422)
      end

      it "mentions the missing field" do
        body = JSON.parse(last_response.body)
        expect(body["error"]).to include("status")
      end
    end

    context "with non-JSON body" do
      before do
        post "/internal/llm-calls",
             "not json",
             "CONTENT_TYPE" => "application/json",
             "HTTP_AUTHORIZATION" => "Bearer #{token}"
      end

      it "returns 400" do
        expect(last_response.status).to eq(400)
      end
    end

    context "with a JSON array instead of object" do
      before do
        post "/internal/llm-calls",
             "[1, 2, 3]",
             "CONTENT_TYPE" => "application/json",
             "HTTP_AUTHORIZATION" => "Bearer #{token}"
      end

      it "returns 400" do
        expect(last_response.status).to eq(400)
      end
    end

    context "without Authorization header" do
      before { post "/internal/llm-calls", valid_body.to_json, "CONTENT_TYPE" => "application/json" }

      it "returns 401" do
        expect(last_response.status).to eq(401)
      end
    end

    context "when store is not configured" do
      before do
        described_class.set(:llm_call_store, nil)
        post_call(valid_body)
      end

      it "returns 503" do
        expect(last_response.status).to eq(503)
      end
    end
  end

  # ----- GET/PATCH /settings/approval-mode -----

  describe "GET and PATCH /settings/approval-mode" do
    let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
    let(:db) { RelayDaemon::Db.new(db_path) }
    let(:store) { RelayDaemon::ApprovalSettingsStore.new(db) }

    before { described_class.set(:approval_settings_store, store) }
    after { db.connection.close }

    def auth_headers
      { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    end

    it "returns the default mode" do
      get "/settings/approval-mode", {}, auth_headers

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("mode" => "ask_on_sensitive")
    end

    it "updates and persists the mode" do
      patch "/settings/approval-mode", JSON.generate("mode" => "full_auto"),
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("mode" => "full_auto")
      expect(store.mode).to eq("full_auto")
    end

    it "rejects an invalid mode" do
      patch "/settings/approval-mode", JSON.generate("mode" => "yolo"),
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)

      expect(last_response.status).to eq(422)
      expect(store.mode).to eq("ask_on_sensitive")
    end

    it "rejects invalid JSON" do
      patch "/settings/approval-mode", "not json",
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)

      expect(last_response.status).to eq(400)
    end

    it "503s when the store isn't configured" do
      described_class.set(:approval_settings_store, nil)

      get "/settings/approval-mode", {}, auth_headers
      expect(last_response.status).to eq(503)

      patch "/settings/approval-mode", JSON.generate("mode" => "full_auto"),
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(503)
    end
  end

  # ----- POST /internal/permission-requests -----

  describe "POST /internal/permission-requests" do
    let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
    let(:db) { RelayDaemon::Db.new(db_path) }
    let(:store) { RelayDaemon::ApprovalSettingsStore.new(db) }
    let(:registry) { RelayDaemon::PermissionRequestRegistry.new }
    let(:config) do
      RelayDaemon::Config.new(
        daemon_token: token, internal_token: internal_token,
        host: "127.0.0.1", port: 7777, db_path: db_path
      )
    end

    before do
      described_class.set(:approval_settings_store, store)
      described_class.set(:permission_request_registry, registry)
      described_class.set(:permission_request_timeout_seconds, 2)
    end
    after { db.connection.close }

    def post_request(body, headers = {})
      post "/internal/permission-requests", JSON.generate(body),
           { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{internal_token}" }.merge(headers)
    end

    it "requires the internal token, not the client daemon token" do
      post "/internal/permission-requests",
           JSON.generate("sessionId" => "s", "toolName" => "Bash", "toolInput" => {}),
           { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token}" }

      expect(last_response.status).to eq(401)
    end

    it "rejects a body missing required fields" do
      post_request("sessionId" => "s1")

      expect(last_response.status).to eq(422)
    end

    it "rejects invalid JSON" do
      post "/internal/permission-requests", "not json",
           { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{internal_token}" }

      expect(last_response.status).to eq(400)
    end

    it "allows immediately in full_auto mode without a live round-trip" do
      store.update_mode!("full_auto")
      events = []
      RelayDaemon::App.settings.event_bus.subscribe { |event| events << event }

      post_request("sessionId" => "s1", "runId" => "r1", "toolName" => "Bash", "toolInput" => { "command" => "rm -rf /" })

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("decision" => "allow")
      expect(events).to be_empty
    end

    it "allows a non-sensitive command immediately in ask_on_sensitive mode" do
      store.update_mode!("ask_on_sensitive")

      post_request("sessionId" => "s1", "runId" => "r1", "toolName" => "Bash", "toolInput" => { "command" => "ls" })

      expect(JSON.parse(last_response.body)).to eq("decision" => "allow")
    end

    def wait_for_requested_event(events)
      Timeout.timeout(2) do
        loop do
          requested = events.find { |event| event["type"] == "tool.permission_requested" }
          break requested if requested

          Thread.pass
        end
      end
    end

    it "escalates a sensitive command in ask_on_sensitive mode and resolves via the client decision" do
      store.update_mode!("ask_on_sensitive")
      events = []
      RelayDaemon::App.settings.event_bus.subscribe { |event| events << event }

      thread = Thread.new do
        post_request("sessionId" => "s1", "runId" => "r1", "toolName" => "Bash", "toolInput" => { "command" => "sudo rm -rf /" })
      end
      requested = wait_for_requested_event(events)

      expect(requested["payload"]).to include("sessionId" => "s1", "agentRunId" => "r1", "toolName" => "Bash")
      request_id = requested["payload"]["requestId"]

      expect(registry.resolve(request_id, "deny")).to be true
      thread.join

      expect(JSON.parse(last_response.body)).to eq("decision" => "deny")
      resolved = events.find { |event| event["type"] == "tool.permission_resolved" }
      expect(resolved["payload"]).to eq(
        "sessionId" => "s1", "agentRunId" => "r1", "requestId" => request_id, "decision" => "deny"
      )
    end

    it "always escalates in ask_every_time mode, even for a harmless command" do
      store.update_mode!("ask_every_time")
      events = []
      RelayDaemon::App.settings.event_bus.subscribe { |event| events << event }

      thread = Thread.new do
        post_request("sessionId" => "s1", "runId" => "r1", "toolName" => "Bash", "toolInput" => { "command" => "ls" })
      end
      requested = wait_for_requested_event(events)

      expect(registry.resolve(requested["payload"]["requestId"], "allow")).to be true
      thread.join

      expect(JSON.parse(last_response.body)).to eq("decision" => "allow")
    end

    it "denies after the timeout when nobody answers" do
      store.update_mode!("ask_every_time")

      post_request("sessionId" => "s1", "runId" => "r1", "toolName" => "Bash", "toolInput" => { "command" => "ls" })

      expect(JSON.parse(last_response.body)).to eq("decision" => "deny")
    end
  end
end
