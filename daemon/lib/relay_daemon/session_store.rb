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

    MAX_TITLE_LENGTH = T.let(200, Integer)

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
        "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at, title)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        [id, repo_id, branch, base_commit, "active", now, nil]
      )

      T.must(find(id))
    end

    sig { params(id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def find(id)
      row = @db.connection.get_first_row(
        "SELECT id, repo_id, branch, base_commit, status, created_at, last_message_at, title
         FROM chat_sessions WHERE id = ?",
        [id]
      )
      row ? row_to_h(row) : nil
    end

    sig { params(repo_id: Integer).returns(T.nilable(T::Hash[String, T.untyped])) }
    def active_for_repo(repo_id)
      row = @db.connection.get_first_row(
        "SELECT id, repo_id, branch, base_commit, status, created_at, last_message_at, title
         FROM chat_sessions WHERE repo_id = ? AND status = 'active'
         ORDER BY created_at ASC LIMIT 1",
        [repo_id]
      )
      row ? row_to_h(row) : nil
    end

    sig do
      params(repo_id: Integer, active: T::Boolean)
        .returns(T::Array[T::Hash[String, T.untyped]])
    end
    def list_for_repo(repo_id, active: true)
      status_clause = active ? " AND status = 'active'" : ""
      @db.connection.execute(
        "SELECT id, repo_id, branch, base_commit, status, created_at, last_message_at, title
         FROM chat_sessions
         WHERE repo_id = ?#{status_clause}
         ORDER BY COALESCE(last_message_at, created_at) DESC, created_at DESC, id DESC",
        [repo_id]
      ).map { |row| row_to_h(row) }
    end

    sig { params(repo_id: Integer).returns(T.nilable(T::Hash[String, T.untyped])) }
    def most_recent_active_for_repo(repo_id)
      list_for_repo(repo_id, active: true).first
    end

    sig { params(id: String, title: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def rename(id, title)
      normalized = normalize_title(title, truncate: false)
      raise ArgumentError, "title is required" if normalized.nil?

      @db.connection.execute(
        "UPDATE chat_sessions SET title = ? WHERE id = ?",
        [normalized, id]
      )
      find(id)
    end

    sig { params(id: String, content: String).void }
    def assign_title_from_first_user_message(id, content)
      normalized = normalize_title(content, truncate: true)
      return if normalized.nil?

      @db.connection.execute(
        "UPDATE chat_sessions SET title = ? WHERE id = ? AND title IS NULL",
        [normalized, id]
      )
    end

    sig { params(id: String, base_commit: String).void }
    def update_base_commit(id, base_commit)
      @db.connection.execute(
        "UPDATE chat_sessions SET base_commit = ? WHERE id = ?",
        [base_commit, id]
      )
    end

    sig { params(id: String).void }
    def touch_last_message(id)
      @db.connection.execute(
        "UPDATE chat_sessions SET last_message_at = ? WHERE id = ?",
        [Time.now.utc.iso8601, id]
      )
    end

    # Marks a session as discarded. The row is kept (not deleted) so stats
    # and eval joins over historical llm_calls/messages keep working.
    sig { params(id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def discard(id)
      @db.connection.execute(
        "UPDATE chat_sessions SET status = 'discarded' WHERE id = ?",
        [id]
      )
      find(id)
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
        "lastMessageAt" => row["last_message_at"],
        "title" => row["title"]
      }
    end

    sig { params(title: String, truncate: T::Boolean).returns(T.nilable(String)) }
    def normalize_title(title, truncate:)
      normalized = title.strip
      return nil if normalized.empty?
      return normalized[0, MAX_TITLE_LENGTH] if truncate
      return normalized if normalized.length <= MAX_TITLE_LENGTH

      raise ArgumentError, "title is too long"
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
      @session_store.assign_title_from_first_user_message(session_id, content) if role == "user"

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

  class SessionTestStore
    extend T::Sig

    sig { params(db: Db, session_store: SessionStore).void }
    def initialize(db, session_store)
      @db = db
      @session_store = session_store
    end

    sig do
      params(session_id: String, tests_passed: T.nilable(T::Boolean))
        .returns(T::Hash[String, T.untyped])
    end
    def record(session_id:, tests_passed:)
      raise ArgumentError, "session not found" unless @session_store.find(session_id)

      now = Time.now.utc.iso8601
      @db.connection.execute(
        "INSERT INTO session_test_runs (session_id, tests_passed, created_at)
         VALUES (?, ?, ?)",
        [session_id, tests_passed.nil? ? nil : (tests_passed ? 1 : 0), now]
      )
      T.must(find(@db.connection.last_insert_row_id))
    end

    sig { params(id: Integer).returns(T.nilable(T::Hash[String, T.untyped])) }
    def find(id)
      row = @db.connection.get_first_row(
        "SELECT id, session_id, tests_passed, created_at FROM session_test_runs WHERE id = ?",
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
        "testsPassed" => row["tests_passed"].nil? ? nil : row["tests_passed"] == 1,
        "createdAt" => row["created_at"]
      }
    end
  end
end
