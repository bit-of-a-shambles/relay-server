# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "relay_daemon/eval_store"
require "securerandom"
require "tmpdir"
require "time"

RSpec.describe RelayDaemon::EvalStore do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }
  let(:store)   { described_class.new(db) }

  after { db.connection.close }

  def repo_id
    @repo_id ||= begin
      db.connection.execute(
        "INSERT INTO repos (path, name, created_at) VALUES (?, ?, ?)",
        ["/tmp/test-repo", "test-repo", Time.now.utc.iso8601]
      )
      db.connection.last_insert_row_id
    end
  end

  # tests_passed: 1, 0, or nil
  def insert_task(tests_passed:, status: "needs_review")
    id = SecureRandom.uuid
    db.connection.execute(
      <<~SQL,
        INSERT INTO tasks (id, repo_id, prompt, quality_dial, status, branch, created_at, tests_passed)
        VALUES (?, ?, 'do the thing', 5, ?, 'relay/x', ?, ?)
      SQL
      [id, repo_id, status, Time.now.utc.iso8601, tests_passed]
    )
    id
  end

  def insert_call(model:, task_id:, cost_usd: 0.001)
    db.connection.execute(
      <<~SQL,
        INSERT INTO llm_calls
          (task_id, requested_model, routed_model, tier, prompt_tokens, completion_tokens,
           cost_usd, frontier_cost_usd, latency_ms, status, created_at)
        VALUES (?, 'requested', ?, 1, 100, 50, ?, 0.01, 100, 'success', ?)
      SQL
      [task_id, model, cost_usd, Time.now.utc.iso8601]
    )
  end

  describe "#model_outcomes" do
    it "is empty for a fresh database" do
      expect(store.model_outcomes).to eq([])
    end

    it "computes a per-model pass rate over distinct tasks that ran tests" do
      passed = insert_task(tests_passed: 1)
      failed = insert_task(tests_passed: 0)
      insert_call(model: "moonshotai/kimi-k2", task_id: passed, cost_usd: 0.001)
      insert_call(model: "moonshotai/kimi-k2", task_id: passed, cost_usd: 0.002)
      insert_call(model: "moonshotai/kimi-k2", task_id: failed, cost_usd: 0.001)

      row = store.model_outcomes.find { |r| r[:model] == "moonshotai/kimi-k2" }
      expect(row[:calls]).to eq(3)
      expect(row[:tasks]).to eq(2)
      expect(row[:tasksWithTests]).to eq(2)
      expect(row[:tasksPassed]).to eq(1)
      expect(row[:passRate]).to be_within(0.0001).of(0.5)
      expect(row[:spendUsd]).to be_within(0.0001).of(0.004)
    end

    it "reports a nil pass rate when no task has a test result yet" do
      untested = insert_task(tests_passed: nil)
      insert_call(model: "deepseek/deepseek-chat", task_id: untested)

      row = store.model_outcomes.find { |r| r[:model] == "deepseek/deepseek-chat" }
      expect(row[:tasks]).to eq(1)
      expect(row[:tasksWithTests]).to eq(0)
      expect(row[:passRate]).to be_nil
    end

    it "excludes calls that are not attributed to a task" do
      db.connection.execute(
        <<~SQL,
          INSERT INTO llm_calls
            (task_id, requested_model, routed_model, tier, prompt_tokens, completion_tokens,
             cost_usd, frontier_cost_usd, latency_ms, status, created_at)
          VALUES (NULL, 'requested', 'orphan-model', 1, 10, 5, 0.001, 0.01, 50, 'success', ?)
        SQL
        [Time.now.utc.iso8601]
      )
      expect(store.model_outcomes.map { |r| r[:model] }).not_to include("orphan-model")
    end

    it "breaks results down per routed model" do
      a = insert_task(tests_passed: 1)
      b = insert_task(tests_passed: 1)
      insert_call(model: "moonshotai/kimi-k2", task_id: a)
      insert_call(model: "deepseek/deepseek-chat", task_id: b)
      expect(store.model_outcomes.map { |r| r[:model] })
        .to eq(["deepseek/deepseek-chat", "moonshotai/kimi-k2"])
    end
  end
end

RSpec.describe "GET /eval/model-outcomes via app" do
  include Rack::Test::Methods

  require "relay_daemon/app"
  require "relay_daemon/config"

  def app
    RelayDaemon::App
  end

  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }
  let(:token)   { "eval-test-token" }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path
    ))
    RelayDaemon::App.set(:stats_db, db)
  end

  after { db.connection.close }

  it "returns 200 with the model-outcomes rollup" do
    repo_id = (db.connection.execute(
      "INSERT INTO repos (path, name, created_at) VALUES ('/tmp/r', 'r', ?)",
      [Time.now.utc.iso8601]
    ) && db.connection.last_insert_row_id)
    task_id = SecureRandom.uuid
    db.connection.execute(
      "INSERT INTO tasks (id, repo_id, prompt, quality_dial, status, branch, created_at, tests_passed) VALUES (?, ?, 'p', 5, 'needs_review', 'relay/x', ?, 1)",
      [task_id, repo_id, Time.now.utc.iso8601]
    )
    db.connection.execute(
      "INSERT INTO llm_calls (task_id, requested_model, routed_model, tier, prompt_tokens, completion_tokens, cost_usd, frontier_cost_usd, latency_ms, status, created_at) VALUES (?, 'requested', 'moonshotai/kimi-k2', 1, 100, 50, 0.001, 0.01, 100, 'success', ?)",
      [task_id, Time.now.utc.iso8601]
    )

    get "/eval/model-outcomes", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["modelOutcomes"]).to be_an(Array)
    row = body["modelOutcomes"].find { |r| r["model"] == "moonshotai/kimi-k2" }
    expect(row["passRate"]).to eq(1.0)
  end

  it "returns 401 without auth" do
    get "/eval/model-outcomes"
    expect(last_response.status).to eq(401)
  end

  it "returns 503 when the database is not configured" do
    RelayDaemon::App.set(:stats_db, nil)
    get "/eval/model-outcomes", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(503)
  end
end
