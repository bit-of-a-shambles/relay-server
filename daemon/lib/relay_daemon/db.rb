# typed: true
# frozen_string_literal: true

require "fileutils"
require "sqlite3"
require "time"
require "sorbet-runtime"

module RelayDaemon
  class Db
    extend T::Sig

    MIGRATIONS_DIR = T.let(
      File.expand_path("../../db/migrations", __dir__),
      String
    )

    sig { params(path: String).void }
    def initialize(path)
      FileUtils.mkdir_p(File.dirname(path))
      @db = T.let(SQLite3::Database.new(path), SQLite3::Database)
      @db.results_as_hash = true
      @db.execute("PRAGMA foreign_keys = ON")
      migrate!
    end

    sig { returns(Db) }
    def self.from_env
      path = T.must(ENV.fetch("RELAY_DB_PATH", File.expand_path("~/.relay/relay.sqlite3")))
      new(path)
    end

    sig { returns(SQLite3::Database) }
    def connection
      @db
    end

    private

    sig { void }
    def migrate!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version    TEXT PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
      SQL

      Dir.glob(File.join(MIGRATIONS_DIR, "*.sql")).sort.each do |file|
        version = File.basename(file, ".sql")
        next if @db.get_first_value(
          "SELECT version FROM schema_migrations WHERE version = ?", version
        )

        @db.execute_batch(File.read(file))
        @db.execute(
          "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
          [version, Time.now.utc.iso8601]
        )
      end
    end
  end
end
