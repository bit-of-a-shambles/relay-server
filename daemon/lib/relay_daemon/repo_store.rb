# typed: true
# frozen_string_literal: true

require "time"
require "sorbet-runtime"
require_relative "db"
require_relative "git"

module RelayDaemon
  class RepoStore
    extend T::Sig

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    # Returns all repos as an array of hashes.
    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def all
      @db.connection.execute("SELECT id, path, name, test_command FROM repos ORDER BY id")
                    .map { |r| row_to_h(r) }
    end

    # Creates a new repo record. Returns the new repo hash.
    # Raises ArgumentError for validation errors, or SQLite3::ConstraintException on duplicate path.
    sig { params(path: String, test_command: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
    def create(path:, test_command: nil)
      raise ArgumentError, "path does not exist" unless File.directory?(path)
      raise ArgumentError, "not a git repository" unless RelayDaemon::Git.new(path).repo?

      name = File.basename(path)
      now  = Time.now.utc.iso8601

      @db.connection.execute(
        "INSERT INTO repos (path, name, test_command, created_at) VALUES (?, ?, ?, ?)",
        [path, name, test_command, now]
      )

      id = @db.connection.last_insert_row_id
      { "id" => id, "path" => path, "name" => name, "testCommand" => test_command }
    end

    # Finds a repo by id. Returns nil when not found.
    sig { params(id: Integer).returns(T.nilable(T::Hash[String, T.untyped])) }
    def find(id)
      row = @db.connection.get_first_row(
        "SELECT id, path, name, test_command FROM repos WHERE id = ?", [id]
      )
      row ? row_to_h(row) : nil
    end

    private

    sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def row_to_h(row)
      {
        "id" => row["id"],
        "path" => row["path"],
        "name" => row["name"],
        "testCommand" => row["test_command"]
      }
    end
  end
end
