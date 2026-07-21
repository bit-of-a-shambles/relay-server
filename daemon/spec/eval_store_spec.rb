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

  def insert_session(id:)
    db.connection.execute(
      <<~SQL,
        INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at)
        VALUES (?, ?, ?, ?, 'active', ?)
      SQL
      [id, repo_id, "relay/session/#{id}", "0" * 40, Time.now.utc.iso8601]
    )
    id
  end

  def insert_session_call(model:, session_id:, created_at:, cost_usd: 0.001)
    db.connection.execute(
      <<~SQL,
        INSERT INTO llm_calls
          (session_id, requested_model, routed_model, tier, prompt_tokens, completion_tokens,
           cost_usd, frontier_cost_usd, latency_ms, status, created_at)
        VALUES (?, 'requested', ?, 1, 100, 50, ?, 0.01, 100, 'success', ?)
      SQL
      [session_id, model, cost_usd, created_at]
    )
  end

  def insert_session_test(session_id:, tests_passed:, created_at:)
    db.connection.execute(
      "INSERT INTO session_test_runs (session_id, tests_passed, created_at) VALUES (?, ?, ?)",
      [session_id, tests_passed, created_at]
    )
  end

  describe "#model_outcomes" do
    it "is empty for a fresh database" do
      expect(store.model_outcomes).to eq([])
    end

    it "computes a per-model pass rate over distinct session outcomes that ran tests" do
      session = insert_session(id: "session-eval-pass-rate")
      insert_session_call(model: "openai/gpt-5.5", session_id: session, created_at: "2026-07-01T10:00:00Z", cost_usd: 0.001)
      insert_session_call(model: "openai/gpt-5.5", session_id: session, created_at: "2026-07-01T10:00:30Z", cost_usd: 0.002)
      insert_session_test(session_id: session, tests_passed: 1, created_at: "2026-07-01T10:01:00Z")
      insert_session_call(model: "openai/gpt-5.5", session_id: session, created_at: "2026-07-01T10:02:00Z", cost_usd: 0.001)
      insert_session_test(session_id: session, tests_passed: 0, created_at: "2026-07-01T10:03:00Z")

      row = store.model_outcomes.find { |r| r[:model] == "openai/gpt-5.5" }
      expect(row[:calls]).to eq(3)
      expect(row[:outcomes]).to eq(2)
      expect(row[:outcomesWithTests]).to eq(2)
      expect(row[:outcomesPassed]).to eq(1)
      expect(row[:passRate]).to be_within(0.0001).of(0.5)
      expect(row[:spendUsd]).to be_within(0.0001).of(0.004)
    end

    it "reports a nil pass rate when no session outcome has a test result yet" do
      session = insert_session(id: "session-eval-untested")
      insert_session_call(model: "x-ai/grok-4.5", session_id: session, created_at: Time.now.utc.iso8601)

      row = store.model_outcomes.find { |r| r[:model] == "x-ai/grok-4.5" }
      expect(row[:outcomes]).to eq(1)
      expect(row[:outcomesWithTests]).to eq(0)
      expect(row[:passRate]).to be_nil
    end

    it "excludes calls that are not attributed to a session" do
      db.connection.execute(
        <<~SQL,
          INSERT INTO llm_calls
            (requested_model, routed_model, tier, prompt_tokens, completion_tokens,
             cost_usd, frontier_cost_usd, latency_ms, status, created_at)
          VALUES ('requested', 'orphan-model', 1, 10, 5, 0.001, 0.01, 50, 'success', ?)
        SQL
        [Time.now.utc.iso8601]
      )
      expect(store.model_outcomes.map { |r| r[:model] }).not_to include("orphan-model")
    end

    it "breaks results down per routed model" do
      a = insert_session(id: "session-model-a")
      b = insert_session(id: "session-model-b")
      insert_session_call(model: "openai/gpt-5.5", session_id: a, created_at: "2026-07-01T10:00:00Z")
      insert_session_test(session_id: a, tests_passed: 1, created_at: "2026-07-01T10:01:00Z")
      insert_session_call(model: "x-ai/grok-4.5", session_id: b, created_at: "2026-07-01T10:00:00Z")
      insert_session_test(session_id: b, tests_passed: 1, created_at: "2026-07-01T10:01:00Z")
      expect(store.model_outcomes.map { |r| r[:model] })
        .to eq(["openai/gpt-5.5", "x-ai/grok-4.5"])
    end

    it "attributes session calls to the first later session test run" do
      session = insert_session(id: "session-eval-1")
      insert_session_call(
        model: "openai/gpt-5.5",
        session_id: session,
        created_at: "2026-07-01T10:00:00Z",
        cost_usd: 0.001
      )
      insert_session_test(
        session_id: session,
        tests_passed: 1,
        created_at: "2026-07-01T10:01:00Z"
      )
      insert_session_call(
        model: "openai/gpt-5.5",
        session_id: session,
        created_at: "2026-07-01T10:02:00Z",
        cost_usd: 0.002
      )
      insert_session_test(
        session_id: session,
        tests_passed: 0,
        created_at: "2026-07-01T10:03:00Z"
      )

      rows = db.connection.execute(
        "SELECT call_id, tests_passed, outcome_tested_at FROM eval_dataset WHERE session_id = ? ORDER BY call_created_at",
        [session]
      )
      expect(rows.map { |row| row["tests_passed"] }).to eq([1, 0])
      expect(rows.map { |row| row["outcome_tested_at"] }).to eq([
        "2026-07-01T10:01:00Z",
        "2026-07-01T10:03:00Z"
      ])

      row = store.model_outcomes.find { |r| r[:model] == "openai/gpt-5.5" }
      expect(row[:calls]).to eq(2)
      expect(row[:outcomes]).to eq(2)
      expect(row[:outcomesWithTests]).to eq(2)
      expect(row[:outcomesPassed]).to eq(1)
      expect(row[:passRate]).to eq(0.5)
      expect(row[:spendUsd]).to be_within(0.0001).of(0.003)
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
    session_id = "session-api-eval"
    db.connection.execute(
      "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at) VALUES (?, ?, ?, ?, 'active', ?)",
      [session_id, repo_id, "relay/session/#{session_id}", "0" * 40, Time.now.utc.iso8601]
    )
    db.connection.execute(
      "INSERT INTO llm_calls (session_id, requested_model, routed_model, tier, prompt_tokens, completion_tokens, cost_usd, frontier_cost_usd, latency_ms, status, created_at) VALUES (?, 'requested', 'openai/gpt-5.5', 1, 100, 50, 0.001, 0.01, 100, 'success', ?)",
      [session_id, "2026-07-01T10:00:00Z"]
    )
    db.connection.execute(
      "INSERT INTO session_test_runs (session_id, tests_passed, created_at) VALUES (?, 1, ?)",
      [session_id, "2026-07-01T10:01:00Z"]
    )

    get "/eval/model-outcomes", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["modelOutcomes"]).to be_an(Array)
    row = body["modelOutcomes"].find { |r| r["model"] == "openai/gpt-5.5" }
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
