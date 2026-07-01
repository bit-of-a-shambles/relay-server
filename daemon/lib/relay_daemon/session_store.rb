# typed: true
# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"
require "sorbet-runtime"
require_relative "db"
require_relative "git"

module RelayDaemon
  class SessionStore
    extend T::Sig

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    sig do
      params(
        repo: T::Hash[String, T.untyped],
        worktrees_dir: String,
        id: T.nilable(String)
      ).returns(T::Hash[String, T.untyped])
    end
    def create(repo:, worktrees_dir:, id: nil)
      id ||= SecureRandom.uuid
      repo_id = Integer(repo.fetch("id"))
      repo_path = String(repo.fetch("path"))
      unless @db.connection.get_first_value("SELECT id FROM repos WHERE id = ?", [repo_id])
        raise ArgumentError, "repo not found"
      end

      branch = "relay/session/#{id}"
      base_commit = Git.new(repo_path).head_sha
      now = Time.now.utc.iso8601
      worktree_path = File.join(worktrees_dir, id)

      FileUtils.mkdir_p(worktrees_dir)
      Git.new(repo_path).worktree_add(worktree_path, branch: branch)

      @db.connection.execute(
        "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
        [id, repo_id, branch, base_commit, "active", now]
      )

      T.must(find(id))
    end

    sig { params(id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def find(id)
      row = @db.connection.get_first_row(
        "SELECT id, repo_id, branch, base_commit, status, created_at, last_message_at
         FROM chat_sessions WHERE id = ?",
        [id]
      )
      row ? row_to_h(row) : nil
    end

    sig { params(id: String).void }
    def touch_last_message(id)
      @db.connection.execute(
        "UPDATE chat_sessions SET last_message_at = ? WHERE id = ?",
        [Time.now.utc.iso8601, id]
      )
    end

    private

    sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def row_to_h(row)
      {
        "id" => row["id"],
        "repoId" => row["repo_id"],
        "branch" => row["branch"],
        "baseCommit" => row["base_commit"],
        "status" => row["status"],
        "createdAt" => row["created_at"],
        "lastMessageAt" => row["last_message_at"]
      }
    end
  end

  class MessageStore
    extend T::Sig

    VALID_ROLES = T.let(%w[user assistant tool system].freeze, T::Array[String])

    sig { params(db: Db, session_store: SessionStore).void }
    def initialize(db, session_store)
      @db = db
      @session_store = session_store
    end

    sig do
      params(
        session_id: String,
        role: String,
        content: String,
        agent_run_id: T.nilable(String),
        id: T.nilable(String)
      ).returns(T::Hash[String, T.untyped])
    end
    def append(session_id:, role:, content:, agent_run_id: nil, id: nil)
      raise ArgumentError, "session not found" unless @session_store.find(session_id)
      raise ArgumentError, "invalid role" unless VALID_ROLES.include?(role)
      raise ArgumentError, "content required" if content.empty?

      id ||= SecureRandom.uuid
      now = Time.now.utc.iso8601
      @db.connection.execute(
        "INSERT INTO messages (id, session_id, role, content, created_at, agent_run_id)
         VALUES (?, ?, ?, ?, ?, ?)",
        [id, session_id, role, content, now, agent_run_id]
      )
      @session_store.touch_last_message(session_id)

      T.must(find(id))
    end

    sig { params(session_id: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def list_for_session(session_id)
      @db.connection.execute(
        "SELECT id, session_id, role, content, created_at, agent_run_id
         FROM messages WHERE session_id = ? ORDER BY created_at ASC, rowid ASC",
        [session_id]
      ).map { |row| row_to_h(row) }
    end

    sig { params(id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def find(id)
      row = @db.connection.get_first_row(
        "SELECT id, session_id, role, content, created_at, agent_run_id
         FROM messages WHERE id = ?",
        [id]
      )
      row ? row_to_h(row) : nil
    end

    private

    sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def row_to_h(row)
      {
        "id" => row["id"],
        "sessionId" => row["session_id"],
        "role" => row["role"],
        "content" => row["content"],
        "createdAt" => row["created_at"],
        "agentRunId" => row["agent_run_id"]
      }
    end
  end
end
