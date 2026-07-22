# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "relay_daemon/eval_store"
require "relay_daemon/provider_store"
require "relay_daemon/routing_config_writer"
require "json"
require "securerandom"
require "tmpdir"
require "time"

RSpec.describe RelayDaemon::RoutingConfigWriter do
  let(:db_path)    { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)         { RelayDaemon::Db.new(db_path) }
  let(:eval_store) { RelayDaemon::EvalStore.new(db) }

  after { db.connection.close }

  def repo_id
    @repo_id ||= begin
      db.connection.execute(
        "INSERT INTO repos (path, name, created_at) VALUES ('/tmp/r', 'r', ?)",
        [Time.now.utc.iso8601]
      )
      db.connection.last_insert_row_id
    end
  end

  def insert_session
    id = "session-#{SecureRandom.uuid}"
    db.connection.execute(
      "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at) " \
      "VALUES (?, ?, ?, ?, 'active', ?)",
      [id, repo_id, "relay/session/#{id}", "0" * 40, Time.now.utc.iso8601]
    )
    id
  end

  def insert_call(model:, session_id:, created_at:)
    db.connection.execute(
      "INSERT INTO llm_calls (session_id, requested_model, routed_model, tier, prompt_tokens, " \
      "completion_tokens, cost_usd, frontier_cost_usd, latency_ms, status, created_at) " \
      "VALUES (?, 'requested', ?, 1, 100, 50, 0.001, 0.01, 100, 'success', ?)",
      [session_id, model, created_at]
    )
  end

  def insert_session_test(session_id:, tests_passed:, created_at:)
    db.connection.execute(
      "INSERT INTO session_test_runs (session_id, tests_passed, created_at) VALUES (?, ?, ?)",
      [session_id, tests_passed, created_at]
    )
  end

  # Record `passed` passing and `failed` failing session outcomes for a model.
  def record(model:, passed: 0, failed: 0)
    (passed + failed).times.with_index do |_, index|
      session_id = insert_session
      call_time = format("2026-07-01T10:%02d:00Z", index)
      test_time = format("2026-07-01T10:%02d:30Z", index)
      tests_passed = index < passed ? 1 : 0
      insert_call(model: model, session_id: session_id, created_at: call_time)
      insert_session_test(session_id: session_id, tests_passed: tests_passed, created_at: test_time)
    end
  end

  describe "#config" do
    it "keeps base tier order when there is no outcome data" do
      writer = described_class.new(eval_store, min_samples: 1)
      expect(writer.config["tiers"]["1"]).to eq(
        ["openai/gpt-5.5", "x-ai/grok-4.5", "z-ai/glm-5.2", "openrouter-auto"]
      )
    end

    it "reorders a tier so the higher-passing model is routed first" do
      record(model: "openai/gpt-5.5",     passed: 1, failed: 1) # 0.5
      record(model: "x-ai/grok-4.5", passed: 2, failed: 0) # 1.0
      writer = described_class.new(eval_store, min_samples: 1)
      expect(writer.config["tiers"]["1"]).to eq(
        ["x-ai/grok-4.5", "openai/gpt-5.5", "z-ai/glm-5.2", "openrouter-auto"]
      )
    end

    it "floats a model with enough samples ahead of one below the threshold" do
      record(model: "x-ai/grok-4.5", passed: 2, failed: 0) # 2 samples
      record(model: "openai/gpt-5.5",     passed: 1, failed: 0) # 1 sample
      writer = described_class.new(eval_store, min_samples: 2)
      # OpenAI has too few samples to score, so Grok (scored) leads.
      expect(writer.config["tiers"]["1"]).to eq(
        ["x-ai/grok-4.5", "openai/gpt-5.5", "z-ai/glm-5.2", "openrouter-auto"]
      )
    end

    it "ignores models with no test results yet" do
      session_id = insert_session
      insert_call(model: "x-ai/grok-4.5", session_id: session_id, created_at: Time.now.utc.iso8601)
      writer = described_class.new(eval_store, min_samples: 1)
      expect(writer.config["tiers"]["1"]).to eq(
        ["openai/gpt-5.5", "x-ai/grok-4.5", "z-ai/glm-5.2", "openrouter-auto"]
      )
    end

    it "preserves rules, quality dial, and frontier model" do
      cfg = described_class.new(eval_store).config
      expect(cfg["rules"]).to include({ "when" => "default", "tier" => 1 })
      expect(cfg["qualityDial"]).to eq("default" => 5)
      expect(cfg["frontierModel"]).to eq("openai/gpt-5.6-sol")
      expect(cfg["targets"]).to include(
        "openrouter-auto" => { "model" => "openrouter/auto-beta" },
        "openrouter-pareto-code" => { "model" => "openrouter/pareto-code" }
      )
    end

    it "defaults providers to an empty hash when no provider store is configured" do
      cfg = described_class.new(eval_store).config
      expect(cfg["providers"]).to eq({})
    end

    it "merges every stored provider, inlining its api key when present" do
      provider_db = RelayDaemon::Db.new(File.join(Dir.mktmpdir, "providers.sqlite3"))
      provider_store = RelayDaemon::ProviderStore.new(provider_db)
      provider_store.create(name: "myvllm", base_url: "http://localhost:8000", api_key: "secret")
      provider_store.create(name: "nokey", base_url: "http://localhost:9000")

      cfg = described_class.new(eval_store, provider_store: provider_store).config

      expect(cfg["providers"]).to eq(
        "myvllm" => { "baseUrl" => "http://localhost:8000", "apiKey" => "secret" },
        "nokey" => { "baseUrl" => "http://localhost:9000" }
      )
      provider_db.connection.close
    end
  end

  describe "#write!" do
    it "writes valid JSON (creating parent dirs) that the router can consume" do
      record(model: "x-ai/grok-4.5", passed: 2, failed: 0)
      path = File.join(Dir.mktmpdir, "nested", "routing.json")
      described_class.new(eval_store, min_samples: 1).write!(path)

      parsed = JSON.parse(File.read(path))
      expect(parsed["tiers"]["1"].first).to eq("x-ai/grok-4.5")
      expect(parsed["rules"].last).to eq("when" => "default", "tier" => 1)
    end

    it "writes the file with mode 0600 (providers may carry inline api keys)" do
      path = File.join(Dir.mktmpdir, "routing.json")
      described_class.new(eval_store, min_samples: 1).write!(path)

      mode = File.stat(path).mode & 0o777
      expect(mode).to eq(0o600)
    end
  end
end
