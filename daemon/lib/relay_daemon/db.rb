# typed: true
# frozen_string_literal: true

require "fileutils"
require "sqlite3"
require "time"
require "sorbet-runtime"

module RelayDaemon
  # Hands out one SQLite3::Database connection per Thread.current so
  # concurrent Puma worker threads never share a handle (SQLite3::Database
  # is not safe to use concurrently from multiple threads). Migrations run
  # exactly once per Db instance, guarded by a Mutex, on the first
  # connection opened by any thread.
  class Db
    extend T::Sig

    MIGRATIONS_DIR = T.let(
      File.expand_path("../../db/migrations", __dir__),
      String
    )

    sig { params(path: String).void }
    def initialize(path)
      FileUtils.mkdir_p(File.dirname(path))
      @path = path
      # Unique per instance so multiple Db objects on the same thread don't
      # collide when stashing their connection in that thread's locals.
      @thread_key = T.let(:"relay_db_connection_#{object_id}", Symbol)
      @migrate_mutex = T.let(Mutex.new, Mutex)
      @migrated = T.let(false, T::Boolean)
      # Eagerly establish (and migrate) the constructing thread's
      # connection so the database file and schema exist as soon as `new`
      # returns, matching the historical (single-connection) behavior.
      connection
    end

    sig { returns(Db) }
    def self.from_env
      path = T.must(ENV.fetch("RELAY_DB_PATH", File.expand_path("~/.relay/relay.sqlite3")))
      new(path)
    end

    # Returns the calling thread's SQLite3::Database handle, opening and
    # configuring it the first time this thread asks. Never shared across
    # threads.
    sig { returns(SQLite3::Database) }
    def connection
      existing = Thread.current[@thread_key]
      return existing if existing

      conn = open_connection
      ensure_migrated(conn)
      Thread.current[@thread_key] = conn
      conn
    end

    # Closes and forgets only the calling thread's handle. Worker threads use
    # this during shutdown so a dead thread never leaves an open SQLite handle.
    sig { returns(T::Boolean) }
    def close_current_connection
      conn = Thread.current[@thread_key]
      return false if conn.nil?

      Thread.current[@thread_key] = nil
      conn.close
      true
    end

    private

    sig { returns(SQLite3::Database) }
    def open_connection
      conn = SQLite3::Database.new(@path)
      conn.results_as_hash = true
      conn.busy_timeout = 5000
      conn.execute("PRAGMA foreign_keys = ON")
      conn.execute("PRAGMA journal_mode = WAL")
      conn
    end

    sig { params(conn: SQLite3::Database).void }
    def ensure_migrated(conn)
      @migrate_mutex.synchronize do
        return if @migrated

        migrate!(conn)
        @migrated = true
      end
    end

    sig { params(conn: SQLite3::Database).void }
    def migrate!(conn)
      conn.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version    TEXT PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
      SQL

      Dir.glob(File.join(MIGRATIONS_DIR, "*.sql")).sort.each do |file|
        version = File.basename(file, ".sql")
        next if conn.get_first_value(
          "SELECT version FROM schema_migrations WHERE version = ?", version
        )

        conn.execute_batch(File.read(file))
        conn.execute(
          "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
          [version, Time.now.utc.iso8601]
        )
      end
    end
  end
end
