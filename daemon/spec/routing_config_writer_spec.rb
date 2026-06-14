# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "relay_daemon/eval_store"
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

  def insert_task(tests_passed:)
    id = SecureRandom.uuid
    db.connection.execute(
      "INSERT INTO tasks (id, repo_id, prompt, quality_dial, status, branch, created_at, tests_passed) " \
      "VALUES (?, ?, 'p', 5, 'needs_review', 'relay/x', ?, ?)",
      [id, repo_id, Time.now.utc.iso8601, tests_passed]
    )
    id
  end

  def insert_call(model:, task_id:)
    db.connection.execute(
      "INSERT INTO llm_calls (task_id, requested_model, routed_model, tier, prompt_tokens, " \
      "completion_tokens, cost_usd, frontier_cost_usd, latency_ms, status, created_at) " \
      "VALUES (?, 'requested', ?, 1, 100, 50, 0.001, 0.01, 100, 'success', ?)",
      [task_id, model, Time.now.utc.iso8601]
    )
  end

  # Record `passed` passing and `failed` failing tasks for a model.
  def record(model:, passed: 0, failed: 0)
    passed.times { insert_call(model: model, task_id: insert_task(tests_passed: 1)) }
    failed.times { insert_call(model: model, task_id: insert_task(tests_passed: 0)) }
  end

  describe "#config" do
    it "keeps base tier order when there is no outcome data" do
      writer = described_class.new(eval_store, min_samples: 1)
      expect(writer.config["tiers"]["1"]).to eq(["moonshotai/kimi-k2", "deepseek/deepseek-chat"])
    end

    it "reorders a tier so the higher-passing model is routed first" do
      record(model: "moonshotai/kimi-k2",     passed: 1, failed: 1) # 0.5
      record(model: "deepseek/deepseek-chat", passed: 2, failed: 0) # 1.0
      writer = described_class.new(eval_store, min_samples: 1)
      expect(writer.config["tiers"]["1"]).to eq(["deepseek/deepseek-chat", "moonshotai/kimi-k2"])
    end

    it "floats a model with enough samples ahead of one below the threshold" do
      record(model: "deepseek/deepseek-chat", passed: 2, failed: 0) # 2 samples
      record(model: "moonshotai/kimi-k2",     passed: 1, failed: 0) # 1 sample
      writer = described_class.new(eval_store, min_samples: 2)
      # kimi has too few samples to score, so deepseek (scored) leads.
      expect(writer.config["tiers"]["1"]).to eq(["deepseek/deepseek-chat", "moonshotai/kimi-k2"])
    end

    it "ignores models with no test results yet" do
      insert_call(model: "deepseek/deepseek-chat", task_id: insert_task(tests_passed: nil))
      writer = described_class.new(eval_store, min_samples: 1)
      expect(writer.config["tiers"]["1"]).to eq(["moonshotai/kimi-k2", "deepseek/deepseek-chat"])
    end

    it "preserves rules, quality dial, and frontier model" do
      cfg = described_class.new(eval_store).config
      expect(cfg["rules"]).to include({ "when" => "default", "tier" => 1 })
      expect(cfg["qualityDial"]).to eq("default" => 5)
      expect(cfg["frontierModel"]).to eq("anthropic/claude-opus-latest")
    end
  end

  describe "#write!" do
    it "writes valid JSON (creating parent dirs) that the router can consume" do
      record(model: "deepseek/deepseek-chat", passed: 2, failed: 0)
      path = File.join(Dir.mktmpdir, "nested", "routing.json")
      described_class.new(eval_store, min_samples: 1).write!(path)

      parsed = JSON.parse(File.read(path))
      expect(parsed["tiers"]["1"].first).to eq("deepseek/deepseek-chat")
      expect(parsed["rules"].last).to eq("when" => "default", "tier" => 1)
    end
  end
end
