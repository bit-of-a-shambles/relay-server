# frozen_string_literal: true
require "spec_helper"
require "relay_daemon/app"

RSpec.describe RelayDaemon::InferenceJobStore do
  include Rack::Test::Methods
  def app = RelayDaemon::App
  let(:db) { RelayDaemon::Db.new(File.join(Dir.mktmpdir, "jobs.sqlite3")) }
  let(:sessions) { RelayDaemon::SessionStore.new(db) }
  let(:repo) { RelayDaemon::RepoStore.new(db).create(path: Dir.mktmpdir) }
  let(:session) { sessions.create(repo: repo, worktrees_dir: Dir.mktmpdir) }
  let(:store) { described_class.new(db) }
  let(:job) { { "responseId" => "response-id", "sessionId" => session["id"], "runId" => "run", "status" => "queued" } }
  let(:headers) { { "HTTP_AUTHORIZATION" => "Bearer job-token", "CONTENT_TYPE" => "application/json" } }
  before do
    app.set(:relay_config, RelayDaemon::Config.new(daemon_token: "job-token", host: "127.0.0.1", port: 7777, db_path: "unused"))
    app.set(:stats_db, db)
  end
  after { db.close_current_connection }

  it "persists states and recovers interrupted waiters without replaying tools" do
    expect(store.record(job)).to include(job)
    store.record(job.merge("status" => "in_progress"))
    store.record(job.merge("responseId" => "done", "status" => "completed"))
    expect { store.record(job.merge("runId" => "other")) }.to raise_error(ArgumentError, /different run/)
    expect { store.record({}) }.to raise_error(ArgumentError)
    expect { store.record(job.merge("status" => "unknown")) }.to raise_error(ArgumentError)
    store.recover!
    expect(store.list(session["id"]).map { |item| item["status"] }.sort).to eq(%w[completed interrupted])
    messages = RelayDaemon::MessageStore.new(db, sessions).list_for_session(session["id"])
    expect(messages.last["content"]).to include("tools were not replayed")
    expect(messages.length).to eq(1)
    store.recover!
    expect(RelayDaemon::MessageStore.new(db, sessions).list_for_session(session["id"]).length).to eq(1)
  end

  it "authenticates updates and reads, publishes queue heartbeats and rejects invalid data" do
    post "/internal/inference-jobs", job.to_json
    expect(last_response.status).to eq(401)
    events = []
    subscription = app.settings.event_bus.subscribe { |event| events << event }
    post "/internal/inference-jobs", job.to_json, headers
    expect(last_response.status).to eq(200)
    expect(events.last).to include("type" => "inference.updated")
    get "/sessions/#{session['id']}/inference-jobs", {}, headers
    expect(JSON.parse(last_response.body).first).to include(job)
    get "/sessions/missing/inference-jobs", {}, headers
    expect(last_response.status).to eq(404)
    post "/internal/inference-jobs", "{", headers
    expect(last_response.status).to eq(400)
    post "/internal/inference-jobs", "{}", headers
    expect(last_response.status).to eq(422)
    app.set(:stats_db, nil)
    post "/internal/inference-jobs", job.to_json, headers
    expect(last_response.status).to eq(503)
    get "/sessions/#{session['id']}/inference-jobs", {}, headers
    expect(last_response.status).to eq(503)
    app.settings.event_bus.unsubscribe(subscription)
  end
end
