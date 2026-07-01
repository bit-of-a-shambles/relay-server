# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "tmpdir"

RSpec.describe RelayDaemon::Db do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }

  subject(:db) { described_class.new(db_path) }

  after { db.connection.close }

  def table_names(database)
    database.connection
            .execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .map { |r| r["name"] }
  end

  describe "schema after first open" do
    it "creates all required tables" do
      expect(table_names(db)).to include(
        "repos", "tasks", "llm_calls", "chat_sessions", "messages", "schema_migrations"
      )
    end

    it "records all migrations in schema_migrations" do
      versions = db.connection
                   .execute("SELECT version FROM schema_migrations ORDER BY version")
                   .map { |r| r["version"] }
      expect(versions).to include(
        "001_initial_schema",
        "002_add_base_commit",
        "006_chat_sessions"
      )
    end

    it "repos table has the expected columns" do
      cols = db.connection
               .execute("PRAGMA table_info(repos)")
               .map { |r| r["name"] }
      expect(cols).to include("id", "path", "name", "test_command", "created_at")
    end

    it "tasks table has the expected columns" do
      cols = db.connection
               .execute("PRAGMA table_info(tasks)")
               .map { |r| r["name"] }
      expect(cols).to include(
        "id", "repo_id", "prompt", "quality_dial", "status",
        "branch", "base_commit", "created_at", "finished_at", "tests_passed",
        "cost_usd", "frontier_cost_usd"
      )
    end

    it "llm_calls table has the expected columns" do
      cols = db.connection
               .execute("PRAGMA table_info(llm_calls)")
               .map { |r| r["name"] }
      expect(cols).to include(
        "id", "task_id", "requested_model", "routed_model", "tier",
        "prompt_tokens", "completion_tokens", "cost_usd", "frontier_cost_usd",
        "latency_ms", "escalation_reason", "status", "error_message", "created_at"
      )
    end

    it "chat_sessions table has the expected columns" do
      cols = db.connection
               .execute("PRAGMA table_info(chat_sessions)")
               .map { |r| r["name"] }
      expect(cols).to include(
        "id", "repo_id", "branch", "base_commit", "status", "created_at",
        "last_message_at"
      )
    end

    it "messages table has the expected columns" do
      cols = db.connection
               .execute("PRAGMA table_info(messages)")
               .map { |r| r["name"] }
      expect(cols).to include(
        "id", "session_id", "role", "content", "created_at", "agent_run_id"
      )
    end
  end

  describe "idempotency" do
    it "does not re-apply migrations on second open" do
      migration_count = Dir.glob(File.join(RelayDaemon::Db::MIGRATIONS_DIR, "*.sql")).size
      db # open once (runs migrations)
      db2 = described_class.new(db_path)
      count = db2.connection
                 .get_first_value("SELECT COUNT(*) FROM schema_migrations")
      expect(count).to eq(migration_count)
      db2.connection.close
    end
  end

  describe "RELAY_DB_PATH" do
    it "uses the path from the environment variable" do
      custom_path = File.join(Dir.mktmpdir, "custom", "relay.sqlite3")
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch)
        .with("RELAY_DB_PATH", anything)
        .and_return(custom_path)

      db2 = described_class.from_env
      expect(File.exist?(custom_path)).to be true
      db2.connection.close
    end
  end

  describe "directory creation" do
    it "creates missing parent directories" do
      nested_path = File.join(Dir.mktmpdir, "a", "b", "c", "relay.sqlite3")
      db2 = described_class.new(nested_path)
      expect(File.exist?(nested_path)).to be true
      db2.connection.close
    end
  end
end
