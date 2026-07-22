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
  let(:routing_config_path) { File.join(Dir.mktmpdir, "routing.json") }

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
      agent_command: "ruby #{SESSION_AGENT} {prompt}",
      routing_config_path: routing_config_path
    ))
    RelayDaemon::App.set(:repo_store, repo_store)
    RelayDaemon::App.set(:session_store, session_store)
    RelayDaemon::App.set(:stats_db, db)
    # A provider store from another spec file may still be set on the
    # shared Sinatra settings and its connection since closed; this file's
    # routing-config writes don't need providers, so keep it unset.
    RelayDaemon::App.set(:provider_store, nil)
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

  describe "multi-thread session lifecycle" do
    def post_repo_session(repo_id, body = {})
      post "/repos/#{repo_id}/sessions", body.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
    end

    def stale_lifecycle_response(session, method, path, body = "")
      locked = Queue.new
      release = Queue.new
      snapshot = Queue.new
      holder = Thread.new do
        RelayDaemon::App.with_repo_lock(repo["id"]) do
          locked << true
          release.pop
        end
      end
      locked.pop

      seen = false
      allow(session_store).to receive(:find).and_wrap_original do |original, id|
        if id == session["id"] && !seen
          seen = true
          snapshot << true
        end
        original.call(id)
      end
      request = Thread.new do
        Rack::MockRequest.new(RelayDaemon::App).public_send(
          method, path, input: body, "CONTENT_TYPE" => "application/json",
          "HTTP_AUTHORIZATION" => "Bearer #{token}"
        )
      end
      snapshot.pop
      session_store.discard(session["id"])
      release << true
      holder.join
      request.join.value
    end

    it "requires auth for repo-scoped and individual session routes" do
      get "/repos/#{repo["id"]}/sessions"
      expect(last_response.status).to eq(401)

      post_repo_session(repo["id"], {})
      expect(last_response.status).to eq(201)
      session_id = JSON.parse(last_response.body)["id"]

      get "/sessions/#{session_id}"
      expect(last_response.status).to eq(401)
      patch "/sessions/#{session_id}", { title: "renamed" }.to_json,
            { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(401)
    end

    it "lists active sessions newest by activity and creates a fresh titled thread" do
      post_repo_session(repo["id"], { title: " first thread " })
      expect(last_response.status).to eq(201)
      first = JSON.parse(last_response.body)
      expect(first["title"]).to eq("first thread")

      post_repo_session(repo["id"], { title: "second thread" })
      second = JSON.parse(last_response.body)
      expect(second["id"]).not_to eq(first["id"])

      db.connection.execute("UPDATE chat_sessions SET last_message_at = ? WHERE id = ?",
                            ["2026-07-15T12:00:00Z", first["id"]])
      db.connection.execute("UPDATE chat_sessions SET last_message_at = ? WHERE id = ?",
                            ["2026-07-15T11:00:00Z", second["id"]])

      get "/repos/#{repo["id"]}/sessions", {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body).map { |item| item["id"] }).to eq([first["id"], second["id"]])

      post_repo_session(999_999)
      expect(last_response.status).to eq(404)
      get "/repos/not-an-id/sessions", {}, auth_headers
      expect(last_response.status).to eq(422)
    end

    it "validates titles before creating or renaming a session" do
      post_repo_session(repo["id"], { title: " " })
      expect(last_response.status).to eq(422)
      post_repo_session(repo["id"], { title: "x" * 201 })
      expect(last_response.status).to eq(422)
      post_repo_session(repo["id"], [])
      expect(last_response.status).to eq(422)

      session = create_session
      patch "/sessions/#{session["id"]}", "not json",
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)
      patch "/sessions/#{session["id"]}", { title: "" }.to_json,
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
      patch "/sessions/#{session["id"]}", { title: "renamed" }.to_json,
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["title"]).to eq("renamed")
    end

    it "handles empty creation bodies and missing dependencies" do
      post "/repos/#{repo["id"]}/sessions", "", auth_headers
      expect(last_response.status).to eq(201)
      session_id = JSON.parse(last_response.body)["id"]

      get "/repos/999999/sessions", {}, auth_headers
      expect(last_response.status).to eq(404)
      post "/repos/not-an-id/sessions", "", auth_headers
      expect(last_response.status).to eq(422)

      RelayDaemon::App.set(:repo_store, nil)
      get "/repos/#{repo["id"]}/sessions", {}, auth_headers
      expect(last_response.status).to eq(503)
      post "/repos/#{repo["id"]}/sessions", "", auth_headers
      expect(last_response.status).to eq(503)
      RelayDaemon::App.set(:repo_store, repo_store)

      RelayDaemon::App.set(:session_store, nil)
      get "/repos/#{repo["id"]}/sessions", {}, auth_headers
      expect(last_response.status).to eq(503)
      post "/repos/#{repo["id"]}/sessions", "", auth_headers
      expect(last_response.status).to eq(503)
      get "/sessions/#{session_id}", {}, auth_headers
      expect(last_response.status).to eq(503)
      patch "/sessions/#{session_id}", { title: "x" }.to_json,
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(503)
      RelayDaemon::App.set(:session_store, session_store)

      get "/sessions/missing", {}, auth_headers
      expect(last_response.status).to eq(404)
      patch "/sessions/missing", { title: "x" }.to_json,
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(404)

      allow(session_store).to receive(:rename).and_return(nil)
      patch "/sessions/#{session_id}", { title: "x" }.to_json,
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(404)
    end

    it "opens individual sessions and resumes the most recently active legacy thread" do
      post_repo_session(repo["id"])
      first = JSON.parse(last_response.body)
      post_repo_session(repo["id"])
      second = JSON.parse(last_response.body)

      db.connection.execute("UPDATE chat_sessions SET last_message_at = ? WHERE id = ?",
                            ["2026-07-15T10:00:00Z", first["id"]])
      db.connection.execute("UPDATE chat_sessions SET last_message_at = ? WHERE id = ?",
                            ["2026-07-15T11:00:00Z", second["id"]])
      post_session
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq(second["id"])

      get "/sessions/#{first["id"]}", {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq(first["id"])
      get "/sessions/missing", {}, auth_headers
      expect(last_response.status).to eq(404)
    end

    it "re-reads active state inside the lock for rename, approve, and discard" do
      post_repo_session(repo["id"])
      rename_session = JSON.parse(last_response.body)
      rename_response = stale_lifecycle_response(
        rename_session, :patch, "/sessions/#{rename_session["id"]}", { title: "late rename" }.to_json
      )
      expect(rename_response.status).to eq(409)

      post_repo_session(repo["id"])
      approve_session = JSON.parse(last_response.body)
      approve_response = stale_lifecycle_response(
        approve_session, :post, "/sessions/#{approve_session["id"]}/approve"
      )
      expect(approve_response.status).to eq(409)
      expect(JSON.parse(approve_response.body)["error"]).to eq("session is not active")

      post_repo_session(repo["id"])
      discard_session = JSON.parse(last_response.body)
      discard_response = stale_lifecycle_response(
        discard_session, :post, "/sessions/#{discard_session["id"]}/discard"
      )
      expect(discard_response.status).to eq(409)
      expect(JSON.parse(discard_response.body)["error"]).to eq("already discarded")
    end

    it "returns not found when a session disappears during each locked re-read" do
      post_repo_session(repo["id"])
      message_session = JSON.parse(last_response.body)
      allow(session_store).to receive(:find).and_return(message_session, nil)
      response = post "/sessions/#{message_session["id"]}/messages", { content: "gone" }.to_json,
                       { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(response.status).to eq(404)
      allow(session_store).to receive(:find).and_call_original

      post_repo_session(repo["id"])
      rename_session = JSON.parse(last_response.body)
      allow(session_store).to receive(:find).and_return(rename_session, nil)
      response = patch "/sessions/#{rename_session["id"]}", { title: "gone" }.to_json,
                       { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(response.status).to eq(404)
      allow(session_store).to receive(:find).and_call_original

      post_repo_session(repo["id"])
      approve_session = JSON.parse(last_response.body)
      allow(session_store).to receive(:find).and_return(approve_session, nil)
      response = post "/sessions/#{approve_session["id"]}/approve", "", auth_headers
      expect(response.status).to eq(404)
      allow(session_store).to receive(:find).and_call_original

      post_repo_session(repo["id"])
      discard_session = JSON.parse(last_response.body)
      allow(session_store).to receive(:find).and_return(discard_session, nil)
      response = post "/sessions/#{discard_session["id"]}/discard", "", auth_headers
      expect(response.status).to eq(404)
    end

    it "returns one legacy winner as 201 and the locked loser as 200 without a second event" do
      events = []
      RelayDaemon::App.settings.event_bus.subscribe { |event| events << event }
      requests = 2.times.map do
        Thread.new do
          Rack::MockRequest.new(RelayDaemon::App).post(
            "/sessions", input: { repoId: repo["id"] }.to_json,
            "CONTENT_TYPE" => "application/json",
            "HTTP_AUTHORIZATION" => "Bearer #{token}"
          )
        end
      end
      responses = requests.map(&:value)

      expect(responses.map(&:status).sort).to eq([200, 201])
      expect(events.count { |event| event["type"] == "session.updated" }).to eq(1)
    end

    it "keeps sibling lifecycle independent and publishes complete update events" do
      events = []
      RelayDaemon::App.settings.event_bus.subscribe { |event| events << event }
      post_repo_session(repo["id"], { title: "keep" })
      first = JSON.parse(last_response.body)
      post_repo_session(repo["id"], { title: "discard me" })
      second = JSON.parse(last_response.body)

      patch "/sessions/#{first["id"]}", { title: "renamed" }.to_json,
            { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(200)
      payload = events.reverse.find { |event| event["type"] == "session.updated" }["payload"]
      expect(payload).to include(
        "sessionId" => first["id"], "repoId" => repo["id"], "title" => "renamed",
        "status" => "active"
      )

      post "/sessions/#{first["id"]}/discard", "", auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["status"]).to eq("discarded")
      expect(Dir.exist?(File.join(worktrees_dir, second["id"]))).to be true
      expect(session_store.find(second["id"])["status"]).to eq("active")

      ["messages", "test", "approve"].each do |action|
        response = if action == "messages"
                     post "/sessions/#{first["id"]}/messages", { content: "nope" }.to_json,
                          { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
                   else
                     post "/sessions/#{first["id"]}/#{action}", "", auth_headers
                   end
        expect(response.status).to eq(409)
      end
    end

    it "keeps an accepted message busy before the runner thread starts" do
      session = create_session
      started = Queue.new
      release = Queue.new
      allow(RelayDaemon::SessionRunner).to receive(:run_async) do |**options|
        started << options[:session_id]
        release.pop
        RelayDaemon::SessionRunner.release(options[:session_id])
        Thread.new {}
      end

      request = Thread.new do
        Rack::MockRequest.new(RelayDaemon::App).post(
          "/sessions/#{session["id"]}/messages",
          input: { content: "accepted" }.to_json,
          "CONTENT_TYPE" => "application/json",
          "HTTP_AUTHORIZATION" => "Bearer #{token}"
        )
      end
      expect(started.pop).to eq(session["id"])

      discard = Rack::MockRequest.new(RelayDaemon::App).post(
        "/sessions/#{session["id"]}/discard",
        "HTTP_AUTHORIZATION" => "Bearer #{token}"
      )
      expect(discard.status).to eq(409)
      expect(Dir.exist?(File.join(worktrees_dir, session["id"]))).to be true

      release << true
      expect(request.join.value.status).to eq(202)
    end

    it "keeps a full test operation busy until its process and retry finish" do
      gate = File.join(Dir.mktmpdir, "test-gate")
      started_file = File.join(Dir.mktmpdir, "test-started")
      File.mkfifo(gate)
      script = File.join(Dir.mktmpdir, "blocking_test.rb")
      File.write(script, "File.write(ARGV.fetch(0), 'started'); File.open(ARGV.fetch(1), 'r').read")
      blocking_repo = repo_store.create(path: make_git_dir, test_command: "ruby #{script} #{started_file} #{gate}")
      session = session_store.create(repo: blocking_repo, worktrees_dir: worktrees_dir)

      request = Thread.new do
        Rack::MockRequest.new(RelayDaemon::App).post(
          "/sessions/#{session["id"]}/test",
          input: "",
          "CONTENT_TYPE" => "application/json",
          "HTTP_AUTHORIZATION" => "Bearer #{token}"
        )
      end
      Timeout.timeout(2) { Thread.pass until File.exist?(started_file) }

      discard = Rack::MockRequest.new(RelayDaemon::App).post(
        "/sessions/#{session["id"]}/discard",
        "HTTP_AUTHORIZATION" => "Bearer #{token}"
      )
      expect(discard.status).to eq(409)
      expect(Dir.exist?(File.join(worktrees_dir, session["id"]))).to be true

      File.open(gate, "w") { |io| io.write("done") }
      expect(request.join.value.status).to eq(200)
      expect(RelayDaemon::SessionRunner.running?(session["id"])).to be false
    end

    it "serializes work for one repo while allowing the lock to be released" do
      entered = Queue.new
      second_started = Queue.new
      release = Queue.new
      finished = Queue.new

      first = Thread.new do
        RelayDaemon::App.with_repo_lock(repo["id"]) do
          entered << true
          release.pop
        end
        finished << :first
      end
      entered.pop

      second = Thread.new do
        second_started << true
        RelayDaemon::App.with_repo_lock(repo["id"]) { finished << :second }
      end
      second_started.pop
      expect(finished.empty?).to be true

      release << true
      first.join
      second.join
      expect([finished.pop, finished.pop]).to eq(%i[first second])
    end

    it "rejects invalid JSON and non-object bodies for repo-scoped creation" do
      post "/repos/#{repo["id"]}/sessions", "not json",
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)
      post_repo_session(repo["id"], [])
      expect(last_response.status).to eq(422)
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
      updates = events.select { |event| event["type"] == "session.updated" }
      expect(updates.length).to be >= 2
      expect(updates.map { |event| event["payload"]["lastMessageAt"] }.all? { |value| !value.nil? }).to be true
      expect(updates.last["payload"]).to include(
        "sessionId" => session["id"], "repoId" => repo["id"], "status" => "active"
      )
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

    it "passes the optional model override to the session agent" do
      session = create_session

      post "/sessions/#{session["id"]}/messages",
           { content: "hello", modelOverride: "x-ai/grok-4.5" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(202)

      messages = wait_for_messages(session["id"], 2)
      expect(messages.last["content"]).to include("model=x-ai/grok-4.5")
    end

    it "passes relay-auto when the client does not override the model" do
      session = create_session

      post "/sessions/#{session["id"]}/messages",
           { content: "hello auto" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(202)

      messages = wait_for_messages(session["id"], 2)
      expect(messages.last["content"]).to include("model=relay-auto")
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

      post "/sessions/#{session["id"]}/messages", { content: "x", modelOverride: "" }.to_json,
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
      expect(db.connection.get_first_value("SELECT tests_passed FROM session_test_runs WHERE session_id = ?", [session["id"]]))
        .to eq(1)

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

    it "auto-retries exactly once with an escalated agent run when tests fail and autoRetry is true" do
      failing_repo = repo_store.create(path: make_git_dir, test_command: "echo boom-output && false")
      session = session_store.create(repo: failing_repo, worktrees_dir: worktrees_dir)
      events = []
      RelayDaemon::App.settings.event_bus.subscribe { |event| events << event }

      post "/sessions/#{session["id"]}/test", { autoRetry: true }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["testsPassed"]).to be false

      messages = wait_for_messages(session["id"], 2)
      expect(messages.map { |message| message["role"] }).to eq(%w[user assistant])
      expect(messages.first["content"]).to include(
        "Tests failed:", "boom-output", "Fix and keep changes minimal."
      )
      expect(messages.last["content"]).to include("mode=resume")

      expect(File.read(File.join(worktrees_dir, session["id"], "env_anthropic_base.txt")))
        .to match(%r{/session/#{session["id"]}/run/[0-9a-f-]+/escalated\z})
      expect(events.map { |event| event["type"] }).to include("message.created", "agent.event")
      updates = events.select { |event| event["type"] == "session.updated" }
      expect(updates.length).to be >= 2
      expect(updates.map { |event| event["payload"]["title"] }.uniq.length).to eq(1)
      expect(updates.map { |event| event["payload"]["lastMessageAt"] }.all? { |value| !value.nil? }).to be true

      # The message barrier above also proves the retry has completed.
      expect(message_store.list_for_session(session["id"]).length).to eq(2)
    end

    it "does not auto-retry when tests pass even if autoRetry is true" do
      session = create_session
      File.write(File.join(worktrees_dir, session["id"], "session_agent_runs.txt"), "ok\n")

      post "/sessions/#{session["id"]}/test", { autoRetry: true }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["testsPassed"]).to be true

      expect(message_store.list_for_session(session["id"])).to eq([])
    end

    it "does not auto-retry on failure by default (autoRetry omitted)" do
      failing_repo = repo_store.create(path: make_git_dir, test_command: "false")
      session = session_store.create(repo: failing_repo, worktrees_dir: worktrees_dir)

      post "/sessions/#{session["id"]}/test", "", auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["testsPassed"]).to be false

      expect(message_store.list_for_session(session["id"])).to eq([])
    end

    it "returns 422 when autoRetry is not a boolean" do
      session = create_session

      post "/sessions/#{session["id"]}/test", { autoRetry: "yes" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
    end

    it "returns 503 when auto-retrying a failed test but no agent command is configured" do
      failing_repo = repo_store.create(path: make_git_dir, test_command: "false")
      session = session_store.create(repo: failing_repo, worktrees_dir: worktrees_dir)
      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
        worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
        agent_command: nil, routing_config_path: routing_config_path
      ))

      post "/sessions/#{session["id"]}/test", { autoRetry: true }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(503)
    end

    it "does not refresh learned routing when learnFromOutcome is false" do
      session = create_session
      File.write(routing_config_path, "unchanged")

      post "/sessions/#{session["id"]}/test",
           { learnFromOutcome: false }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)

      expect(last_response.status).to eq(200)
      expect(File.read(routing_config_path)).to eq("unchanged")
      row = db.connection.get_first_row(
        "SELECT learn_from_outcome FROM session_test_runs WHERE session_id = ? ORDER BY id DESC LIMIT 1",
        [session["id"]]
      )
      expect(row["learn_from_outcome"]).to eq(0)
    end

    it "returns action errors" do
      get "/sessions/missing/diff", {}, auth_headers
      expect(last_response.status).to eq(404)
      post "/sessions/missing/test", "", auth_headers
      expect(last_response.status).to eq(404)
      post "/sessions/missing/approve", "", auth_headers
      expect(last_response.status).to eq(404)

      session = create_session
      post "/sessions/#{session["id"]}/test", "not json",
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)
      post "/sessions/#{session["id"]}/test", [].to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)
      post "/sessions/#{session["id"]}/test", { learnFromOutcome: "false" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)

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

    it "returns 503 when the database is missing for test" do
      session = create_session
      RelayDaemon::App.set(:stats_db, nil)

      post "/sessions/#{session["id"]}/test", "", auth_headers
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

  describe "POST /sessions/:id/discard" do
    def post_discard(id)
      post "/sessions/#{id}/discard", "", auth_headers
    end

    it "removes the worktree and branch, marks the session discarded, and frees the repo" do
      session = create_session
      events = []
      RelayDaemon::App.settings.event_bus.subscribe { |event| events << event }

      post_discard(session["id"])
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["status"]).to eq("discarded")

      expect(Dir.exist?(File.join(worktrees_dir, session["id"]))).to be false
      branch_out, = Open3.capture3("git", "-C", git_dir, "branch", "--list", session["branch"])
      expect(branch_out.strip).to eq("")

      updated_events = events.select { |event| event["type"] == "session.updated" }
      expect(updated_events.map { |event| event["payload"]["sessionId"] }).to include(session["id"])

      # active_for_repo excludes the discarded session, so a new one can open.
      post_session
      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)["id"]).not_to eq(session["id"])
    end

    it "returns 404 for an unknown session" do
      post_discard("missing")
      expect(last_response.status).to eq(404)
    end

    it "returns 409 for an already-discarded session" do
      session = create_session
      post_discard(session["id"])
      expect(last_response.status).to eq(200)

      post_discard(session["id"])
      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body)["error"]).to eq("already discarded")
    end

    it "returns 409 while an agent run is in flight, then succeeds once the run finishes" do
      session = create_session
      post "/sessions/#{session["id"]}/messages",
           { content: "slow discard test" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(202)
      Timeout.timeout(2) { Thread.pass until RelayDaemon::SessionRunner.running?(session["id"]) }

      post_discard(session["id"])
      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body)["error"]).to eq("agent run in progress")

      wait_for_messages(session["id"], 2)

      post_discard(session["id"])
      expect(last_response.status).to eq(200)
    end

    it "returns 422 when the session repo is missing" do
      id = orphan_session
      post_discard(id)
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to eq("repo not found")
    end

    it "returns 503 when session store or repo store is not configured" do
      session = create_session

      RelayDaemon::App.set(:session_store, nil)
      post_discard(session["id"])
      expect(last_response.status).to eq(503)
      RelayDaemon::App.set(:session_store, session_store)

      RelayDaemon::App.set(:repo_store, nil)
      post_discard(session["id"])
      expect(last_response.status).to eq(503)
      RelayDaemon::App.set(:repo_store, repo_store)
    end
  end
end
