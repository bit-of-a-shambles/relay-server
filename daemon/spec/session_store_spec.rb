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
        "lastMessageAt" => nil
      )
      expect(session["baseCommit"]).to match(/\A[0-9a-f]{40}\z/)
      expect(Dir.exist?(File.join(worktrees_dir, "session-1"))).to be true
      expect(RelayDaemon::Git.new(File.join(worktrees_dir, "session-1")).current_branch)
        .to eq("relay/session/session-1")

      rows = db.connection.get_first_value("SELECT COUNT(*) FROM chat_sessions")
      expect(rows).to eq(1)
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
