# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/repo_store"

RSpec.describe RelayDaemon::ExecutionConfig do
  include Rack::Test::Methods
  def app = RelayDaemon::App
  let(:path) { File.join(Dir.mktmpdir, "execution.sqlite3") }
  let(:db) { RelayDaemon::Db.new(path) }
  let(:store) { described_class.new(db) }
  let(:sessions) { RelayDaemon::SessionStore.new(db) }
  let(:repos) { RelayDaemon::RepoStore.new(db) }
  let(:worktrees) { Dir.mktmpdir }
  let(:repo) { repos.create(path: Dir.mktmpdir) }
  let(:headers) { { "HTTP_AUTHORIZATION" => "Bearer execution-test", "CONTENT_TYPE" => "application/json" } }
  let(:choice) { { "harnessId" => "codex", "providerId" => "doubleword", "modelId" => "vendor/model", "inferenceMode" => "async" } }

  before do
    app.set(:relay_config, RelayDaemon::Config.new(daemon_token: "execution-test", host: "127.0.0.1", port: 7777, db_path: path, worktrees_dir: worktrees))
    app.set(:stats_db, db)
    app.set(:repo_store, repos)
    app.set(:session_store, sessions)
  end
  after { db.close_current_connection }

  it "validates identifiers and excludes credentials" do
    [nil, [], { "apiKey" => "secret" }, { "harnessId" => "unknown" }, { "providerId" => "../bad" },
     { "providerId" => 1 }, { "modelId" => " " }, { "modelId" => 42 },
     { "inferenceMode" => "batch" }, { "inferenceMode" => "async" }].each do |invalid|
      expect { described_class.validate(invalid) }.to raise_error(ArgumentError)
    end
    expect(described_class.validate({})).to eq(described_class::LEGACY)
  end

  it "persists defaults and snapshots choices for new threads" do
    first = sessions.create(repo: repo, worktrees_dir: worktrees)
    expect(store.defaults).to eq(described_class::LEGACY)
    expect(store.update_defaults(choice)).to eq(choice)
    second = sessions.create(repo: repo, worktrees_dir: worktrees)
    explicit = sessions.create(repo: repo, worktrees_dir: worktrees, execution: { "harnessId" => "omp" })
    reopened = RelayDaemon::Db.new(path)
    expect(described_class.new(reopened).defaults).to eq(choice)
    expect(sessions.find(first["id"])["execution"]).to eq(described_class::LEGACY)
    expect(sessions.find(second["id"])["execution"]).to eq(choice)
    expect(explicit["execution"]["harnessId"]).to eq("omp")
    reopened.close_current_connection
  end

  it "keeps pre-migration rows on legacy choices independent of defaults" do
    old = sessions.create(repo: repo, worktrees_dir: worktrees)
    db.connection.execute("UPDATE chat_sessions SET execution_config = NULL WHERE id = ?", [old["id"]])
    store.update_defaults(choice)
    expect(sessions.find(old["id"])).to include("execution" => described_class::LEGACY, "harnessSessionId" => nil)
  end

  it "serves and updates authenticated defaults with useful errors" do
    get "/execution-defaults"
    expect(last_response.status).to eq(401)
    get "/execution-defaults", {}, headers
    expect(JSON.parse(last_response.body)).to eq(described_class::LEGACY)
    put "/execution-defaults", choice.to_json, headers
    expect(JSON.parse(last_response.body)).to eq(choice)
    put "/execution-defaults", "{", headers
    expect(last_response.status).to eq(400)
    put "/execution-defaults", { "harnessId" => "bad" }.to_json, headers
    expect(last_response.status).to eq(422)
    app.set(:stats_db, nil)
    get "/execution-defaults", {}, headers
    expect(last_response.status).to eq(503)
    put "/execution-defaults", "{}", headers
    expect(last_response.status).to eq(503)
  end

  it "keeps the legacy open endpoint compatible and refuses to silently reuse different choices" do
    post "/sessions", { repoId: repo["id"], execution: choice }.to_json, headers
    expect(last_response.status).to eq(201)
    expect(JSON.parse(last_response.body)["execution"]).to eq(choice)
    post "/sessions", { repoId: repo["id"], execution: {} }.to_json, headers
    expect(last_response.status).to eq(409)
    post "/sessions", { repoId: repo["id"], execution: false }.to_json, headers
    expect(last_response.status).to eq(422)
  end

  it "creates an explicitly configured thread and rejects invalid execution before creating a workspace" do
    post "/repos/#{repo['id']}/sessions", { execution: choice }.to_json, headers
    expect(last_response.status).to eq(201)
    expect(JSON.parse(last_response.body)["execution"]).to eq(choice)
    post "/repos/#{repo['id']}/sessions", { execution: { apiKey: "secret" } }.to_json, headers
    expect(last_response.status).to eq(422)
    expect(Dir.children(worktrees).length).to eq(1)
  end
end
