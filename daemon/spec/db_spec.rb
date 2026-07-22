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
        "repos", "tasks", "llm_calls", "chat_sessions", "messages",
        "session_test_runs", "push_devices", "schema_migrations"
      )
    end

    it "records all migrations in schema_migrations" do
      versions = db.connection
                   .execute("SELECT version FROM schema_migrations ORDER BY version")
                   .map { |r| r["version"] }
      expect(versions).to include(
        "001_initial_schema",
        "002_add_base_commit",
        "006_chat_sessions",
        "007_session_eval_attribution",
        "012_push_devices",
        "013_session_titles_and_repo_activity"
      )
    end

    it "repos table has the expected columns" do
      cols = db.connection
               .execute("PRAGMA table_info(repos)")
               .map { |r| r["name"] }
      expect(cols).to include("id", "path", "name", "test_command", "created_at")
    end

    it "adds nullable session titles and the repo activity index" do
      columns = db.connection.execute("PRAGMA table_info(chat_sessions)")
      title = columns.find { |row| row["name"] == "title" }

      expect(title["notnull"]).to eq(0)
      indexes = db.connection.execute("PRAGMA index_list(chat_sessions)")
      expect(indexes.map { |row| row["name"] }).to include(
        "idx_chat_sessions_repo_status_activity"
      )
    end

    it "backfills the first nonblank user message with Ruby-compatible trimming and truncation" do
      legacy_path = File.join(Dir.mktmpdir, "legacy.sqlite3")
      seed_database_at_migration_012(legacy_path)

      migrated_db = described_class.new(legacy_path)
      rows = migrated_db.connection.execute(
        "SELECT id, title FROM chat_sessions ORDER BY id"
      )

      expect(rows).to eq([
        { "id" => "backfill-blank-first", "title" => "usable title" },
        { "id" => "backfill-long", "title" => "x" * 200 }
      ])
      migrated_db.connection.close
    end

    it "keeps the historical tasks table for old call-log joins" do
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
        "latency_ms", "escalation_reason", "status", "error_message", "created_at",
        "session_id"
      )
    end

    it "chat_sessions table has the expected columns" do
      cols = db.connection
               .execute("PRAGMA table_info(chat_sessions)")
               .map { |r| r["name"] }
      expect(cols).to include(
        "id", "repo_id", "branch", "base_commit", "status", "created_at",
        "last_message_at", "title"
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

    it "session_test_runs table has the expected columns" do
      cols = db.connection
               .execute("PRAGMA table_info(session_test_runs)")
               .map { |r| r["name"] }
      expect(cols).to include(
        "id", "session_id", "tests_passed", "learn_from_outcome", "created_at"
      )
    end

    it "push_devices table has the expected columns and uniqueness" do
      cols = db.connection
               .execute("PRAGMA table_info(push_devices)")
               .map { |r| r["name"] }
      expect(cols).to eq(["device_token", "created_at"])

      indexes = db.connection.execute("PRAGMA index_list(push_devices)")
      expect(indexes.any? { |index| index["unique"] == 1 }).to be true
    end
  end

  describe "locale independence" do
    it "migrates under a US-ASCII default external encoding" do
      # POSIX/C locales (launchd, minimal CI containers) make Ruby default
      # File.read to US-ASCII; migrations contain UTF-8 bytes and must still
      # apply.
      original = Encoding.default_external
      verbose = $VERBOSE
      begin
        $VERBOSE = nil
        Encoding.default_external = Encoding::US_ASCII
        expect { described_class.new(db_path).connection.close }.not_to raise_error
      ensure
        Encoding.default_external = original
        $VERBOSE = verbose
      end
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

  describe "thread safety" do
    it "gives every thread its own connection object" do
      main_conn = db.connection

      queue = Queue.new
      threads = Array.new(6) { Thread.new { queue << db.connection.object_id } }
      threads.each(&:join)

      ids = Array.new(6) { queue.pop }
      expect(ids.uniq.size).to eq(6)
      expect(ids).not_to include(main_conn.object_id)
    end

    it "returns the same connection object on repeated calls from the same thread" do
      first = db.connection
      second = db.connection
      expect(first.object_id).to eq(second.object_id)
    end

    it "closes and clears only the current thread connection so it can reopen safely" do
      db.connection
      results = Queue.new
      worker = Thread.new do
        results << db.close_current_connection
        first = db.connection
        results << db.close_current_connection
        second = db.connection
        results << (first.object_id != second.object_id)
        results << db.close_current_connection
      end
      worker.join

      expect(4.times.map { results.pop }).to eq([false, true, true, true])
      expect(db.connection).not_to be_nil
    end

    it "lets many threads insert and read concurrently without BusyException or lost writes" do
      thread_count = 25
      errors = Queue.new

      threads = Array.new(thread_count) do |i|
        Thread.new do
          conn = db.connection
          path = "/tmp/relay-thread-safety-#{i}"
          conn.execute(
            "INSERT INTO repos (path, name, test_command, created_at) VALUES (?, ?, ?, ?)",
            [path, "repo-#{i}", nil, Time.now.utc.iso8601]
          )
          row = conn.get_first_row("SELECT id, path FROM repos WHERE path = ?", [path])
          errors << "missing row for #{path}" if row.nil?
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)

      problems = []
      problems << errors.pop until errors.empty?
      expect(problems).to eq([])

      count = db.connection.get_first_value("SELECT COUNT(*) FROM repos")
      expect(count).to eq(thread_count)
    end

    it "runs migrate! exactly once even when many threads race for the first connection" do
      # Force the "not yet migrated" state back on so every thread below
      # contends for the migration mutex as if this were the first access.
      db.instance_variable_set(:@migrated, false)

      call_count = 0
      count_mutex = Mutex.new
      allow(db).to receive(:migrate!).and_wrap_original do |original, *args|
        count_mutex.synchronize { call_count += 1 }
        original.call(*args)
      end

      threads = Array.new(10) { Thread.new { db.connection } }
      threads.each(&:join)

      expect(call_count).to eq(1)
    end
  end

  private

  def seed_database_at_migration_012(path)
    connection = SQLite3::Database.new(path)
    connection.results_as_hash = true
    connection.execute(
      "CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"
    )

    Dir.glob(File.join(RelayDaemon::Db::MIGRATIONS_DIR, "*.sql")).sort
      .reject { |file| File.basename(file, ".sql") > "012_push_devices" }
      .each do |file|
        version = File.basename(file, ".sql")
        connection.execute_batch(File.read(file))
        connection.execute(
          "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
          [version, "2026-01-01T00:00:00Z"]
        )
      end

    connection.execute(
      "INSERT INTO repos (id, path, name, created_at) VALUES (?, ?, ?, ?)",
      [1, "/tmp/legacy-repo", "legacy-repo", "2026-01-01T00:00:00Z"]
    )
    connection.execute(
      "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at)
       VALUES (?, ?, ?, ?, ?, ?)",
      ["backfill-long", 1, "relay/session/long", "0" * 40, "active", "2026-01-01T00:00:00Z"]
    )
    connection.execute(
      "INSERT INTO chat_sessions (id, repo_id, branch, base_commit, status, created_at)
       VALUES (?, ?, ?, ?, ?, ?)",
      ["backfill-blank-first", 1, "relay/session/blank", "0" * 40, "active", "2026-01-01T00:00:00Z"]
    )
    connection.execute(
      "INSERT INTO messages (id, session_id, role, content, created_at)
       VALUES (?, ?, ?, ?, ?)",
      ["long-message", "backfill-long", "user", " \t\n#{"x" * 205}\r\n", "2026-01-01T00:00:00Z"]
    )
    connection.execute(
      "INSERT INTO messages (id, session_id, role, content, created_at)
       VALUES (?, ?, ?, ?, ?)",
      ["blank-message", "backfill-blank-first", "user", " \t\n\r ", "2026-01-01T00:00:00Z"]
    )
    connection.execute(
      "INSERT INTO messages (id, session_id, role, content, created_at)
       VALUES (?, ?, ?, ?, ?)",
      ["usable-message", "backfill-blank-first", "user", " \tusable title\n", "2026-01-01T00:00:01Z"]
    )
    connection.close
  end
end
