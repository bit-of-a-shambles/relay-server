# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/git"
require "relay_daemon/repo_store"
require "relay_daemon/session_store"

SESSION_AGENT = File.expand_path("support/fake_session_agent.rb", __dir__)

RSpec.describe "Sessions API" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db) { RelayDaemon::Db.new(db_path) }
  let(:repo_store) { RelayDaemon::RepoStore.new(db) }
  let(:session_store) { RelayDaemon::SessionStore.new(db) }
  let(:message_store) { RelayDaemon::MessageStore.new(db, session_store) }
  let(:token) { "sessions-test-token" }
  let(:worktrees_dir) { Dir.mktmpdir }
  let(:agent_log_dir) { Dir.mktmpdir }

  let(:git_dir) do
    dir = make_git_dir
    File.write(File.join(dir, "existing.txt"), "line1\n")
    Open3.capture3("git", "-C", dir, "add", "existing.txt")
    Open3.capture3("git", "-C", dir,
                   "-c", "user.email=t@t.com", "-c", "user.name=T",
                   "-c", "commit.gpgsign=false",
                   "commit", "-m", "add existing file")
    dir
  end

  let(:repo) { repo_store.create(path: git_dir, test_command: "test -f session_agent_runs.txt") }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
      worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
      agent_command: "ruby #{SESSION_AGENT} {prompt}"
    ))
    RelayDaemon::App.set(:repo_store, repo_store)
    RelayDaemon::App.set(:session_store, session_store)
    RelayDaemon::App.set(:stats_db, db)
  end

  after { db.connection.close }

  def auth_headers
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def post_session(body = { repoId: repo["id"] })
    post "/sessions", body.to_json, { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
  end

  def create_session
    post_session
    JSON.parse(last_response.body)
  end

  def wait_for_messages(session_id, count)
    deadline = Time.now + 5
    loop do
      messages = message_store.list_for_session(session_id)
      return messages if messages.length >= count
      raise "timeout waiting for messages" if Time.now > deadline

      sleep 0.05
    end
  end

  def orphan_session(id = "22222222-2222-4222-8222-222222222222")
    db.connection.execute("PRAGMA foreign_keys = OFF")
    db.connection.execute(
      "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at)
       VALUES (?, ?, ?, ?, ?, ?)",
      [id, 99_999, "relay/session/#{id}", "0" * 40, "active", Time.now.utc.iso8601]
    )
    db.connection.execute("PRAGMA foreign_keys = ON")
    id
  end

  describe "POST /sessions" do
    it "creates an active session and returns it" do
      post_session
      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body["repoId"]).to eq(repo["id"])
      expect(body["status"]).to eq("active")
      expect(body["branch"]).to match(%r{\Arelay/session/})
      expect(Dir.exist?(File.join(worktrees_dir, body["id"]))).to be true
    end

    it "returns the existing active session for a repo" do
      first = create_session
      post_session
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq(first["id"])
    end

    it "returns validation and configuration errors" do
      post "/sessions", "not json", { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)

      post_session({})
      expect(last_response.status).to eq(422)

      post_session(repoId: 99_999)
      expect(last_response.status).to eq(422)

      RelayDaemon::App.set(:repo_store, nil)
      post_session
      expect(last_response.status).to eq(503)
      RelayDaemon::App.set(:repo_store, repo_store)

      RelayDaemon::App.set(:session_store, nil)
      post_session
      expect(last_response.status).to eq(503)
    end
  end

  describe "session messages" do
    it "lists messages and posts a new user message that invokes the session runner" do
      session = create_session
      events = []
      RelayDaemon::App.settings.event_bus.subscribe { |event| events << event }

      get "/sessions/#{session["id"]}/messages", {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq([])

      post "/sessions/#{session["id"]}/messages",
           { content: "hello" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(202)
      expect(JSON.parse(last_response.body)["id"]).to be_a(String)

      messages = wait_for_messages(session["id"], 2)
      expect(messages.map { |message| message["role"] }).to eq(%w[user assistant])
      expect(messages.last["content"]).to include("mode=session-id", "prompt=hello")
      expect(events.map { |event| event["type"] }).to include("message.created", "agent.event")
    end

    it "resumes the existing agent session on the second message" do
      session = create_session
      2.times do |index|
        post "/sessions/#{session["id"]}/messages",
             { content: "message #{index}" }.to_json,
             { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
        expect(last_response.status).to eq(202)
        wait_for_messages(session["id"], (index + 1) * 2)
      end

      messages = message_store.list_for_session(session["id"])
      expect(messages.last["content"]).to include("mode=resume", "prompt=message 1")
    end

    it "returns validation and not-found errors" do
      session = create_session

      get "/sessions/missing/messages", {}, auth_headers
      expect(last_response.status).to eq(404)

      post "/sessions/#{session["id"]}/messages", "not json",
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)

      post "/sessions/#{session["id"]}/messages", {}.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)

      post "/sessions/#{session["id"]}/messages", [].to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)

      post "/sessions/missing/messages", { content: "x" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(404)

      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
        worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
        agent_command: nil
      ))
      post "/sessions/#{session["id"]}/messages", { content: "x" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(503)
    end

    it "returns 503 when message dependencies are not configured" do
      session = create_session

      RelayDaemon::App.set(:stats_db, nil)
      get "/sessions/#{session["id"]}/messages", {}, auth_headers
      expect(last_response.status).to eq(503)

      post "/sessions/#{session["id"]}/messages", { content: "x" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(503)

      RelayDaemon::App.set(:stats_db, db)
      RelayDaemon::App.set(:session_store, nil)
      get "/sessions/#{session["id"]}/messages", {}, auth_headers
      expect(last_response.status).to eq(503)
      post "/sessions/#{session["id"]}/messages", { content: "x" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(503)
    end
  end

  describe "session actions" do
    it "returns diff, runs tests, and approves without closing the session" do
      session = create_session
      File.write(File.join(worktrees_dir, session["id"], "new.txt"), "created\n")
      Open3.capture3("git", "-C", File.join(worktrees_dir, session["id"]), "add", "new.txt")
      Open3.capture3("git", "-C", File.join(worktrees_dir, session["id"]),
                     "-c", "user.email=t@t.com", "-c", "user.name=T",
                     "-c", "commit.gpgsign=false",
                     "commit", "-m", "session edit")

      get "/sessions/#{session["id"]}/diff", {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body).map { |diff| diff["file"] }).to include("new.txt")

      File.write(File.join(worktrees_dir, session["id"], "session_agent_runs.txt"), "ok\n")
      post "/sessions/#{session["id"]}/test", "", auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["testsPassed"]).to be true

      post "/sessions/#{session["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(200)
      approved = JSON.parse(last_response.body)
      expect(approved["status"]).to eq("active")
      expect(File.exist?(File.join(git_dir, "new.txt"))).to be true
    end

    it "returns nil testsPassed when the repo has no test command" do
      no_test_repo = repo_store.create(path: make_git_dir)
      session = session_store.create(repo: no_test_repo, worktrees_dir: worktrees_dir)

      post "/sessions/#{session["id"]}/test", "", auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["testsPassed"]).to be_nil
    end

    it "returns false testsPassed when the repo test command fails" do
      failing_repo = repo_store.create(path: make_git_dir, test_command: "false")
      session = session_store.create(repo: failing_repo, worktrees_dir: worktrees_dir)

      post "/sessions/#{session["id"]}/test", "", auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["testsPassed"]).to be false
    end

    it "returns action errors" do
      get "/sessions/missing/diff", {}, auth_headers
      expect(last_response.status).to eq(404)
      post "/sessions/missing/test", "", auth_headers
      expect(last_response.status).to eq(404)
      post "/sessions/missing/approve", "", auth_headers
      expect(last_response.status).to eq(404)

      session = create_session
      RelayDaemon::App.set(:session_store, nil)
      get "/sessions/#{session["id"]}/diff", {}, auth_headers
      expect(last_response.status).to eq(503)
      post "/sessions/#{session["id"]}/test", "", auth_headers
      expect(last_response.status).to eq(503)
      post "/sessions/#{session["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(503)
    end

    it "returns 503 when repo store is missing for test and approve" do
      session = create_session
      RelayDaemon::App.set(:repo_store, nil)

      post "/sessions/#{session["id"]}/test", "", auth_headers
      expect(last_response.status).to eq(503)
      post "/sessions/#{session["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(503)
    end

    it "returns 422 when the session repo is missing for test and approve" do
      id = orphan_session

      post "/sessions/#{id}/test", "", auth_headers
      expect(last_response.status).to eq(422)
      post "/sessions/#{id}/approve", "", auth_headers
      expect(last_response.status).to eq(422)
    end

    it "returns 409 merge_conflict when approving a conflicting session branch" do
      session = create_session
      worktree = File.join(worktrees_dir, session["id"])
      File.write(File.join(worktree, "existing.txt"), "session change\n")
      Open3.capture3("git", "-C", worktree, "add", "existing.txt")
      Open3.capture3("git", "-C", worktree,
                     "-c", "user.email=t@t.com", "-c", "user.name=T",
                     "-c", "commit.gpgsign=false",
                     "commit", "-m", "session conflict")

      File.write(File.join(git_dir, "existing.txt"), "base change\n")
      Open3.capture3("git", "-C", git_dir, "add", "existing.txt")
      Open3.capture3("git", "-C", git_dir,
                     "-c", "user.email=t@t.com", "-c", "user.name=T",
                     "-c", "commit.gpgsign=false",
                     "commit", "-m", "base conflict")

      post "/sessions/#{session["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body)["error"]).to eq("merge_conflict")
    end

    it "returns 500 when approving a session whose branch is missing" do
      session = create_session
      git = RelayDaemon::Git.new(git_dir)
      git.worktree_remove(File.join(worktrees_dir, session["id"]))
      git.delete_branch(session["branch"])

      post "/sessions/#{session["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(500)
      expect(JSON.parse(last_response.body)["error"]).to include("git merge failed")
    end
  end
end
