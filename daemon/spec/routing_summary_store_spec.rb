# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "relay_daemon/repo_store"
require "relay_daemon/routing_summary_store"
require "relay_daemon/session_store"

RSpec.describe RelayDaemon::RoutingSummaryStore do
  let(:db) { RelayDaemon::Db.new(File.join(Dir.mktmpdir, "routing-summary.sqlite3")) }
  let(:repo) { RelayDaemon::RepoStore.new(db).create(path: make_git_dir) }
  let(:sessions) { RelayDaemon::SessionStore.new(db) }
  let(:session) { sessions.create(repo: repo, worktrees_dir: Dir.mktmpdir) }
  let(:other_session) { sessions.create(repo: repo, worktrees_dir: Dir.mktmpdir) }

  after { db.connection.close }

  def insert_call(session_id:, run_id:, requested_model:, target:, model:, cost:, escalation: nil, status: "success")
    db.connection.execute(
      <<~SQL,
        INSERT INTO llm_calls
          (session_id, run_id, requested_model, route_target, routed_model, tier,
           prompt_tokens, completion_tokens, cost_usd, frontier_cost_usd,
           latency_ms, escalation_reason, status, created_at)
        VALUES (?, ?, ?, ?, ?, 1, 10, 5, ?, 0.01, 100, ?, ?, ?)
      SQL
      [session_id, run_id, requested_model, target, model, cost, escalation, status, Time.now.utc.iso8601]
    )
  end

  it "aggregates all attempts by run without crossing session boundaries" do
    insert_call(
      session_id: session["id"], run_id: "run-auto", requested_model: "relay-auto",
      target: "openrouter-auto", model: "google/gemini-2.5-flash-lite", cost: 0.01
    )
    insert_call(
      session_id: session["id"], run_id: "run-auto", requested_model: "relay-auto",
      target: "openai/gpt-5.5", model: "openai/gpt-5.5", cost: 0.03, escalation: "retry"
    )
    insert_call(
      session_id: other_session["id"], run_id: "run-auto", requested_model: "relay-auto",
      target: "secret-target", model: "secret-model", cost: 9.0
    )

    expect(described_class.new(db).list_for_session(session["id"])).to eq(
      [
        {
          "runId" => "run-auto",
          "isAuto" => true,
          "routeTargets" => ["openrouter-auto", "openai/gpt-5.5"],
          "actualModels" => ["google/gemini-2.5-flash-lite", "openai/gpt-5.5"],
          "callCount" => 2,
          "costUsd" => 0.04,
          "escalated" => true
        }
      ]
    )
  end

  it "keeps direct runs and reports unknown aggregate cost when any call has no cost" do
    insert_call(
      session_id: session["id"], run_id: "run-direct", requested_model: "openai/gpt-5.5",
      target: "openai/gpt-5.5", model: "openai/gpt-5.5", cost: nil, status: "error"
    )
    insert_call(
      session_id: session["id"], run_id: nil, requested_model: "relay-auto",
      target: "legacy", model: "legacy", cost: 1.0
    )

    expect(described_class.new(db).list_for_session(session["id"])).to eq(
      [
        {
          "runId" => "run-direct",
          "isAuto" => false,
          "routeTargets" => ["openai/gpt-5.5"],
          "actualModels" => ["openai/gpt-5.5"],
          "callCount" => 1,
          "costUsd" => nil,
          "escalated" => false
        }
      ]
    )
  end
end
