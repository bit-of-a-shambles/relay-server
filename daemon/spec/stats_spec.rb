# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "relay_daemon/stats"
require "tmpdir"
require "time"

RSpec.describe RelayDaemon::Stats do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }
  let(:stats)   { described_class.new(db) }

  after { db.connection.close }

  def insert_call(model:, cost_usd: 0.001, frontier_cost_usd: 0.01,
                  prompt_tokens: 100, completion_tokens: 50,
                  created_at: Time.now.utc.iso8601)
    db.connection.execute(
      <<~SQL,
        INSERT INTO llm_calls
          (requested_model, routed_model, tier, prompt_tokens, completion_tokens,
           cost_usd, frontier_cost_usd, latency_ms, status, created_at)
        VALUES (?, ?, 1, ?, ?, ?, ?, 100, 'success', ?)
      SQL
      ["requested", model, prompt_tokens, completion_tokens,
       cost_usd, frontier_cost_usd, created_at]
    )
  end

  def ensure_repo
    existing = db.connection.get_first_value("SELECT id FROM repos LIMIT 1")
    return existing if existing

    db.connection.execute(
      "INSERT INTO repos (path, name, created_at) VALUES (?, ?, ?)",
      ["/tmp/test-repo", "test-repo", Time.now.utc.iso8601]
    )
    db.connection.last_insert_row_id
  end

  def insert_task(status:, created_at: Time.now.utc.iso8601)
    repo_id = ensure_repo
    id = SecureRandom.uuid
    db.connection.execute(
      <<~SQL,
        INSERT INTO tasks (id, repo_id, prompt, quality_dial, status, branch, created_at)
        VALUES (?, ?, 'test prompt', 5, ?, 'relay/test', ?)
      SQL
      [id, repo_id, status, created_at]
    )
    id
  end

  describe "#compute with empty database" do
    it "returns zero spend and nil task success rate" do
      result = stats.compute
      expect(result[:spendUsd]).to eq(0.0)
      expect(result[:frontierCostUsd]).to eq(0.0)
      expect(result[:savedUsd]).to eq(0.0)
      expect(result[:taskCount]).to eq(0)
      expect(result[:taskSuccessRate]).to be_nil
      expect(result[:perModel]).to eq([])
    end

    it "defaults to 30d range" do
      result = stats.compute
      expect(result[:range]).to eq("30d")
    end
  end

  describe "#compute with call records" do
    before do
      insert_call(model: "moonshotai/kimi-k2",    cost_usd: 0.001, frontier_cost_usd: 0.01, prompt_tokens: 100, completion_tokens: 50)
      insert_call(model: "moonshotai/kimi-k2",    cost_usd: 0.002, frontier_cost_usd: 0.02, prompt_tokens: 200, completion_tokens: 80)
      insert_call(model: "deepseek/deepseek-chat", cost_usd: 0.0005, frontier_cost_usd: 0.005, prompt_tokens: 50, completion_tokens: 20)
    end

    it "aggregates spend across all calls" do
      result = stats.compute
      expect(result[:spendUsd]).to be_within(0.0001).of(0.0035)
    end

    it "aggregates frontier cost" do
      result = stats.compute
      expect(result[:frontierCostUsd]).to be_within(0.0001).of(0.035)
    end

    it "computes saved as frontier minus actual spend" do
      result = stats.compute
      expect(result[:savedUsd]).to be_within(0.0001).of(0.0315)
    end

    it "breaks down by routed model" do
      result = stats.compute
      models = result[:perModel].map { |r| r[:model] }
      expect(models).to include("moonshotai/kimi-k2", "deepseek/deepseek-chat")
    end

    it "sums token counts per model" do
      result = stats.compute
      kimi = result[:perModel].find { |r| r[:model] == "moonshotai/kimi-k2" }
      expect(kimi[:calls]).to eq(2)
      expect(kimi[:promptTokens]).to eq(300)
      expect(kimi[:completionTokens]).to eq(130)
    end

    it "treats NULL cost_usd as 0 spend" do
      db.connection.execute(
        "INSERT INTO llm_calls (requested_model, routed_model, tier, prompt_tokens, completion_tokens, cost_usd, frontier_cost_usd, latency_ms, status, created_at) VALUES (?,?,1,10,5,NULL,0.001,50,'success',?)",
        ["r", "null-cost-model", Time.now.utc.iso8601]
      )
      result = stats.compute
      null_model = result[:perModel].find { |r| r[:model] == "null-cost-model" }
      expect(null_model[:spendUsd]).to eq(0.0)
    end
  end

  describe "#compute Phase 2 acceptance: ≥2 models with nonzero savedUsd" do
    it "shows nonzero savings when calls went to cheaper models" do
      insert_call(model: "moonshotai/kimi-k2",    cost_usd: 0.001, frontier_cost_usd: 0.05)
      insert_call(model: "deepseek/deepseek-chat", cost_usd: 0.0005, frontier_cost_usd: 0.04)
      result = stats.compute
      expect(result[:perModel].length).to be >= 2
      expect(result[:savedUsd]).to be > 0
    end
  end

  describe "#compute task success rate" do
    it "is nil when no tasks exist" do
      expect(stats.compute[:taskSuccessRate]).to be_nil
    end

    it "counts approved tasks as successful" do
      insert_task(status: "approved")
      insert_task(status: "approved")
      insert_task(status: "rejected")
      insert_task(status: "failed")
      result = stats.compute
      expect(result[:taskSuccessRate]).to be_within(0.0001).of(0.5)
    end

    it "counts total tasks regardless of status for taskCount" do
      insert_task(status: "queued")
      insert_task(status: "running")
      insert_task(status: "approved")
      expect(stats.compute[:taskCount]).to eq(3)
    end
  end

  describe "range filtering" do
    it "excludes calls older than the range window" do
      old_time = (Time.now.utc - 31 * 24 * 3600).iso8601
      insert_call(model: "old-model", cost_usd: 1.0, frontier_cost_usd: 10.0, created_at: old_time)
      insert_call(model: "new-model", cost_usd: 0.001, frontier_cost_usd: 0.01)

      result = stats.compute(range: "30d")
      models = result[:perModel].map { |r| r[:model] }
      expect(models).not_to include("old-model")
      expect(models).to include("new-model")
    end

    it "accepts all valid range values" do
      %w[7d 30d 90d all].each do |range|
        expect { stats.compute(range: range) }.not_to raise_error
      end
    end

    it "includes everything for 'all' range" do
      old_time = (Time.now.utc - 365 * 24 * 3600).iso8601
      insert_call(model: "ancient-model", cost_usd: 1.0, frontier_cost_usd: 5.0, created_at: old_time)
      result = stats.compute(range: "all")
      expect(result[:perModel].map { |r| r[:model] }).to include("ancient-model")
    end
  end

  describe "invalid range" do
    it "raises ArgumentError" do
      expect { stats.compute(range: "bad") }.to raise_error(ArgumentError, /invalid range/)
    end
  end
end

RSpec.describe "GET /stats via app" do
  include Rack::Test::Methods

  require "relay_daemon/app"
  require "relay_daemon/config"

  def app
    RelayDaemon::App
  end

  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }
  let(:token)   { "stats-test-token" }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path
    ))
    RelayDaemon::App.set(:stats_db, db)
  end

  after { db.connection.close }

  it "returns 200 with JSON stats for valid range" do
    get "/stats?range=30d", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["range"]).to eq("30d")
    expect(body).to include("spendUsd", "frontierCostUsd", "savedUsd", "taskCount", "perModel")
  end

  it "defaults to 30d range" do
    get "/stats", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["range"]).to eq("30d")
  end

  it "returns 422 for unknown range" do
    get "/stats?range=forever", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(422)
  end

  it "returns 401 without auth" do
    get "/stats"
    expect(last_response.status).to eq(401)
  end

  it "returns 503 when db not configured" do
    RelayDaemon::App.set(:stats_db, nil)
    get "/stats", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(503)
  end
end
