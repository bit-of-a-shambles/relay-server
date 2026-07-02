# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/llm_call_store"
require "relay_daemon/repo_store"
require "relay_daemon/session_store"
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

    it "returns status ok and version" do
      body = JSON.parse(last_response.body)
      expect(body).to eq({ "status" => "ok", "version" => "0.1.0" })
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
        requestedModel: "claude-3-haiku",
        routedModel: "moonshotai/kimi-k2",
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
        expect(rows.first["requested_model"]).to eq("claude-3-haiku")
      end

      it "persists the provider column" do
        row = db.connection.execute("SELECT provider FROM llm_calls ORDER BY id DESC LIMIT 1").first
        expect(row["provider"]).to eq("openrouter")
      end

      it "persists session attribution and leaves historical task attribution empty" do
        repo = RelayDaemon::RepoStore.new(db).create(path: make_git_dir)
        session = RelayDaemon::SessionStore.new(db).create(repo: repo, worktrees_dir: Dir.mktmpdir)

        post_call(valid_body.merge(sessionId: session["id"]))

        row = db.connection.execute("SELECT task_id, session_id FROM llm_calls ORDER BY id DESC LIMIT 1").first
        expect(row["task_id"]).to be_nil
        expect(row["session_id"]).to eq(session["id"])
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
end
