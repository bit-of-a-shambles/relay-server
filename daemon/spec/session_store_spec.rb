# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "relay_daemon/git"
require "relay_daemon/repo_store"
require "relay_daemon/session_store"

RSpec.describe RelayDaemon::SessionStore do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db) { RelayDaemon::Db.new(db_path) }
  let(:repo_store) { RelayDaemon::RepoStore.new(db) }
  let(:worktrees_dir) { Dir.mktmpdir }
  let(:repo_path) { make_git_dir }
  let(:repo) { repo_store.create(path: repo_path) }

  subject(:store) { described_class.new(db) }

  after { db.connection.close }

  describe "#create" do
    it "creates an active chat session row and session worktree" do
      session = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "session-1")

      expect(session).to include(
        "id" => "session-1",
        "repoId" => repo["id"],
        "branch" => "relay/session/session-1",
        "status" => "active",
        "lastMessageAt" => nil,
        "title" => nil
      )
      expect(session["baseCommit"]).to match(/\A[0-9a-f]{40}\z/)
      expect(Dir.exist?(File.join(worktrees_dir, "session-1"))).to be true
      expect(RelayDaemon::Git.new(File.join(worktrees_dir, "session-1")).current_branch)
        .to eq("relay/session/session-1")

      rows = db.connection.get_first_value("SELECT COUNT(*) FROM chat_sessions")
      expect(rows).to eq(1)
    end

    it "gives two sessions for one repo distinct branches and worktrees" do
      first = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "first")
      second = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "second")

      expect(first["branch"]).not_to eq(second["branch"])
      expect(File.join(worktrees_dir, first["id"])).to satisfy { |path| Dir.exist?(path) }
      expect(File.join(worktrees_dir, second["id"])).to satisfy { |path| Dir.exist?(path) }
    end

    it "returns nil from find for an unknown session" do
      expect(store.find("missing")).to be_nil
    end

    it "raises before creating a worktree when the repo row is missing" do
      stale_repo = { "id" => 99_999, "path" => repo_path }

      expect do
        store.create(repo: stale_repo, worktrees_dir: worktrees_dir, id: "missing-repo")
      end.to raise_error(ArgumentError, "repo not found")

      expect(Dir.exist?(File.join(worktrees_dir, "missing-repo"))).to be false
    end
  end

  describe "#discard" do
    it "sets status to discarded and keeps the row" do
      session = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "session-2")

      discarded = store.discard(session["id"])

      expect(discarded["status"]).to eq("discarded")
      expect(store.find(session["id"])["status"]).to eq("discarded")
    end
  end

  describe "#active_for_repo" do
    it "returns the active session for a repo" do
      session = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "session-3")

      expect(store.active_for_repo(repo["id"])["id"]).to eq(session["id"])
    end

    it "returns nil when there is no active session" do
      expect(store.active_for_repo(repo["id"])).to be_nil
    end

    it "excludes a discarded session so a new one can be created" do
      session = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "session-4")
      store.discard(session["id"])

      expect(store.active_for_repo(repo["id"])).to be_nil
    end
  end

  describe "#list_for_repo and #most_recent_active_for_repo" do
    it "lists active sessions newest by message activity by default" do
      older = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "older")
      newer = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "newer")
      db.connection.execute("UPDATE chat_sessions SET last_message_at = ? WHERE id = ?", ["2026-01-01T00:00:00Z", older["id"]])
      db.connection.execute("UPDATE chat_sessions SET last_message_at = ? WHERE id = ?", ["2026-01-02T00:00:00Z", newer["id"]])

      expect(store.list_for_repo(repo["id"]).map { |session| session["id"] }).to eq(%w[newer older])
      expect(store.most_recent_active_for_repo(repo["id"])["id"]).to eq("newer")
    end

    it "can include discarded sessions" do
      session = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "discarded-list")
      store.discard(session["id"])

      expect(store.list_for_repo(repo["id"], active: false).map { |item| item["id"] })
        .to include(session["id"])
      expect(store.list_for_repo(repo["id"]).map { |item| item["id"] })
        .not_to include(session["id"])
    end

    it "returns nil when a repo has no active sessions" do
      expect(store.most_recent_active_for_repo(repo["id"])).to be_nil
    end

    it "renames a session after trimming and rejects blank or oversized titles" do
      session = store.create(repo: repo, worktrees_dir: worktrees_dir, id: "rename-me")

      expect(store.rename(session["id"], "  My session  ")["title"]).to eq("My session")
      expect { store.rename(session["id"], " \t ") }.to raise_error(ArgumentError, "title is required")
      expect { store.rename(session["id"], "x" * 201) }.to raise_error(ArgumentError, "title is too long")
    end
  end
end

RSpec.describe RelayDaemon::SessionTestStore do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db) { RelayDaemon::Db.new(db_path) }
  let(:repo_store) { RelayDaemon::RepoStore.new(db) }
  let(:session_store) { RelayDaemon::SessionStore.new(db) }
  let(:test_store) { described_class.new(db, session_store) }
  let(:repo) { repo_store.create(path: make_git_dir) }
  let(:session) { session_store.create(repo: repo, worktrees_dir: Dir.mktmpdir, id: "test-session") }

  after { db.connection.close }

  it "records passed, failed, and unconfigured session test results" do
    expect(test_store.record(session_id: session["id"], tests_passed: true))
      .to include("sessionId" => session["id"], "testsPassed" => true)
    expect(test_store.record(session_id: session["id"], tests_passed: false)["testsPassed"])
      .to be false
    expect(test_store.record(session_id: session["id"], tests_passed: nil)["testsPassed"])
      .to be_nil
  end

  it "raises when recording a result for an unknown session" do
    expect do
      test_store.record(session_id: "missing", tests_passed: true)
    end.to raise_error(ArgumentError, "session not found")
  end

  it "returns nil for an unknown test run" do
    expect(test_store.find(123_456)).to be_nil
  end
end

RSpec.describe RelayDaemon::MessageStore do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db) { RelayDaemon::Db.new(db_path) }
  let(:repo_store) { RelayDaemon::RepoStore.new(db) }
  let(:session_store) { RelayDaemon::SessionStore.new(db) }
  let(:message_store) { described_class.new(db, session_store) }
  let(:worktrees_dir) { Dir.mktmpdir }
  let(:repo) { repo_store.create(path: make_git_dir) }
  let(:session) { session_store.create(repo: repo, worktrees_dir: worktrees_dir, id: "chat-1") }

  after { db.connection.close }

  describe "#append and #list_for_session" do
    it "appends messages and lists them in insertion order" do
      user = message_store.append(
        session_id: session["id"],
        role: "user",
        content: "hello",
        id: "message-1"
      )
      assistant = message_store.append(
        session_id: session["id"],
        role: "assistant",
        content: "hi",
        agent_run_id: "run-1",
        id: "message-2"
      )

      expect(user).to include("role" => "user", "content" => "hello", "agentRunId" => nil)
      expect(assistant).to include(
        "role" => "assistant",
        "content" => "hi",
        "agentRunId" => "run-1"
      )
      expect(message_store.list_for_session(session["id"]).map { |message| message["id"] })
        .to eq(%w[message-1 message-2])
      expect(session_store.find(session["id"])["lastMessageAt"]).not_to be_nil
      expect(session_store.find(session["id"])["title"]).to eq("hello")
    end

    it "assigns the first nonblank user message as a bounded title only once" do
      message_store.append(session_id: session["id"], role: "assistant", content: "answer")
      long_content = "  #{"x" * 205}  "
      message_store.append(session_id: session["id"], role: "user", content: long_content)
      message_store.append(session_id: session["id"], role: "user", content: "second")

      expect(session_store.find(session["id"])["title"]).to eq("x" * 200)
    end

    it "does not assign a title from a blank user message" do
      message_store.append(session_id: session["id"], role: "user", content: "   ")

      expect(session_store.find(session["id"])["title"]).to be_nil
    end

    it "returns an empty list for an unknown session" do
      expect(message_store.list_for_session("missing")).to eq([])
    end

    it "returns nil from find for an unknown message" do
      expect(message_store.find("missing")).to be_nil
    end

    it "raises when appending to an unknown session" do
      expect do
        message_store.append(session_id: "missing", role: "user", content: "hello")
      end.to raise_error(ArgumentError, "session not found")
    end

    it "raises on invalid role" do
      expect do
        message_store.append(session_id: session["id"], role: "bad", content: "hello")
      end.to raise_error(ArgumentError, "invalid role")
    end

    it "raises on empty content" do
      expect do
        message_store.append(session_id: session["id"], role: "user", content: "")
      end.to raise_error(ArgumentError, "content required")
    end
  end
end
