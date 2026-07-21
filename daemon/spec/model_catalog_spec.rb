# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/model_catalog"
require "relay_daemon/routing_config_writer"
require "relay_daemon/eval_store"
require "relay_daemon/provider_store"
require "relay_daemon/db"
require "json"
require "tmpdir"

RSpec.describe RelayDaemon::ModelCatalog do
  describe "#catalog" do
    it "returns the built-in default, sorted ascending by tier, when path is nil" do
      result = described_class.new(nil).catalog

      expect(result["source"]).to eq("default")
      expect(result["frontierModel"]).to eq("openai/gpt-5.6-sol")
      expect(result["tiers"].map { |t| t["tier"] }).to eq([0, 1, 2, 3])
      expect(result["tiers"].first).to eq({ "tier" => 0, "models" => ["deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-pro"] })
      expect(result["custom"]).to eq([])
    end

    it "lists every stored provider's models as providerName::modelId under 'custom'" do
      provider_db = RelayDaemon::Db.new(File.join(Dir.mktmpdir, "providers.sqlite3"))
      provider_store = RelayDaemon::ProviderStore.new(provider_db)
      provider_store.create(name: "myvllm", base_url: "http://localhost:8000", models: ["llama-3", "qwen"])
      provider_store.create(name: "nomodels", base_url: "http://localhost:9000")

      result = described_class.new(nil, provider_store: provider_store).catalog

      expect(result["custom"]).to eq(["myvllm::llama-3", "myvllm::qwen"])
      provider_db.connection.close
    end

    it "returns the built-in default when the file does not exist" do
      missing_path = File.join(Dir.mktmpdir, "does-not-exist.json")

      result = described_class.new(missing_path).catalog

      expect(result["source"]).to eq("default")
      expect(result["frontierModel"]).to eq("openai/gpt-5.6-sol")
    end

    it "returns the built-in default when the file contains malformed JSON" do
      path = File.join(Dir.mktmpdir, "routing.json")
      File.write(path, "{ not valid json")

      result = described_class.new(path).catalog

      expect(result["source"]).to eq("default")
    end

    it "reads a valid file and reports source file, sorted ascending by tier" do
      path = File.join(Dir.mktmpdir, "routing.json")
      File.write(path, JSON.generate({
        "tiers" => {
          "2" => ["openai/gpt-5.6-terra"],
          "0" => ["deepseek/deepseek-v4-flash"]
        },
        "frontierModel" => "openai/gpt-5.6-sol"
      }))

      result = described_class.new(path).catalog

      expect(result["source"]).to eq("file")
      expect(result["tiers"].map { |t| t["tier"] }).to eq([0, 2])
      expect(result["frontierModel"]).to eq("openai/gpt-5.6-sol")
    end

    it "reflects a config written by RoutingConfigWriter (write then read round trip)" do
      db_path = File.join(Dir.mktmpdir, "test.sqlite3")
      db = RelayDaemon::Db.new(db_path)
      begin
        repo_id = db.connection.execute(
          "INSERT INTO repos (path, name, created_at) VALUES ('/tmp/r', 'r', ?)",
          [Time.now.utc.iso8601]
        ) && db.connection.last_insert_row_id
        session_id = "session-catalog"
        db.connection.execute(
          "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at) " \
          "VALUES (?, ?, ?, ?, 'active', ?)",
          [session_id, repo_id, "relay/session/#{session_id}", "0" * 40, Time.now.utc.iso8601]
        )
        db.connection.execute(
          "INSERT INTO llm_calls (session_id, requested_model, routed_model, tier, prompt_tokens, " \
          "completion_tokens, cost_usd, frontier_cost_usd, latency_ms, status, created_at) VALUES " \
          "(?, 'requested', 'x-ai/grok-4.5', 1, 100, 50, 0.001, 0.01, 100, 'success', ?)",
          [session_id, "2026-07-01T10:00:00Z"]
        )
        db.connection.execute(
          "INSERT INTO session_test_runs (session_id, tests_passed, created_at) VALUES (?, 1, ?)",
          [session_id, "2026-07-01T10:01:00Z"]
        )

        path = File.join(Dir.mktmpdir, "routing.json")
        RelayDaemon::RoutingConfigWriter.new(RelayDaemon::EvalStore.new(db), min_samples: 1).write!(path)

        result = described_class.new(path).catalog

        expect(result["source"]).to eq("file")
        tier1 = result["tiers"].find { |t| t["tier"] == 1 }
        # Grok has a measured 100% pass rate, so it is reordered to the
        # front of tier 1. Unscored GLM stays after the base-order models.
        expect(tier1["models"]).to eq(["x-ai/grok-4.5", "openai/gpt-5.5", "z-ai/glm-5.2"])
      ensure
        db.connection.close
      end
    end
  end
end

RSpec.describe "GET /models via app" do
  include Rack::Test::Methods

  require "relay_daemon/app"
  require "relay_daemon/config"

  def app
    RelayDaemon::App
  end

  let(:token) { "models-test-token" }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: "/tmp/relay_models_test.db"
    ))
    RelayDaemon::App.set(:provider_store, nil)
  end

  it "returns 401 without auth" do
    get "/models"
    expect(last_response.status).to eq(401)
  end

  it "returns the default catalog when no routing config path is set" do
    get "/models", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["source"]).to eq("default")
    expect(body["tiers"].map { |t| t["tier"] }).to eq([0, 1, 2, 3])
    expect(body["frontierModel"]).to eq("openai/gpt-5.6-sol")
    expect(body["custom"]).to eq([])
  end

  it "lists a provider created via POST /providers under 'custom'" do
    require "relay_daemon/provider_store"
    provider_db = RelayDaemon::Db.new(File.join(Dir.mktmpdir, "providers.sqlite3"))
    RelayDaemon::App.set(:provider_store, RelayDaemon::ProviderStore.new(provider_db))

    post "/providers",
         { name: "myvllm", baseUrl: "http://localhost:8000", models: ["llama-3"] }.to_json,
         { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(201)

    get "/models", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    body = JSON.parse(last_response.body)
    expect(body["custom"]).to eq(["myvllm::llama-3"])
  end

  it "reflects a config written by RoutingConfigWriter after write-then-GET" do
    db_path = File.join(Dir.mktmpdir, "test.sqlite3")
    db = RelayDaemon::Db.new(db_path)
    begin
      repo_id = db.connection.execute(
        "INSERT INTO repos (path, name, created_at) VALUES ('/tmp/r', 'r', ?)",
        [Time.now.utc.iso8601]
      ) && db.connection.last_insert_row_id
      session_id = "session-catalog-app"
      db.connection.execute(
        "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at) " \
        "VALUES (?, ?, ?, ?, 'active', ?)",
        [session_id, repo_id, "relay/session/#{session_id}", "0" * 40, Time.now.utc.iso8601]
      )
      db.connection.execute(
        "INSERT INTO llm_calls (session_id, requested_model, routed_model, tier, prompt_tokens, " \
        "completion_tokens, cost_usd, frontier_cost_usd, latency_ms, status, created_at) VALUES " \
        "(?, 'requested', 'x-ai/grok-4.5', 1, 100, 50, 0.001, 0.01, 100, 'success', ?)",
        [session_id, "2026-07-01T10:00:00Z"]
      )
      db.connection.execute(
        "INSERT INTO session_test_runs (session_id, tests_passed, created_at) VALUES (?, 1, ?)",
        [session_id, "2026-07-01T10:01:00Z"]
      )

      routing_path = File.join(Dir.mktmpdir, "routing.json")
      RelayDaemon::RoutingConfigWriter.new(RelayDaemon::EvalStore.new(db), min_samples: 1).write!(routing_path)

      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
        routing_config_path: routing_path
      ))

      get "/models", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["source"]).to eq("file")
      tier1 = body["tiers"].find { |t| t["tier"] == 1 }
      expect(tier1["models"]).to eq(["x-ai/grok-4.5", "openai/gpt-5.5", "z-ai/glm-5.2"])
    ensure
      db.connection.close
    end
  end
end
