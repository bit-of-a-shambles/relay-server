# typed: true
# frozen_string_literal: true

require "json"
require "time"
require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  # CRUD store for daemon-managed custom OpenAI-compatible providers (M45).
  # Backs GET/POST /providers and DELETE /providers/:name, and feeds
  # RoutingConfigWriter's "providers" section plus ModelCatalog's "custom"
  # model group. Rows returned by this store include the raw api_key;
  # callers exposing them to untrusted clients (see RelayDaemon::App) must
  # redact it themselves into a "hasApiKey" boolean.
  class ProviderStore
    extend T::Sig

    NAME_PATTERN  = T.let(/\A[a-z0-9_-]+\z/, Regexp)
    RESERVED_NAME = "openrouter"

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    # Returns all providers as an array of hashes, ordered by name.
    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def all
      @db.connection.execute("SELECT name, base_url, api_key, models FROM providers ORDER BY name")
                    .map { |r| row_to_h(r) }
    end

    # Creates a new provider record. Returns the new provider hash.
    # Raises ArgumentError for validation errors, or SQLite3::ConstraintException on duplicate name.
    sig do
      params(
        name: String,
        base_url: String,
        api_key: T.nilable(String),
        models: T::Array[String]
      ).returns(T::Hash[String, T.untyped])
    end
    def create(name:, base_url:, api_key: nil, models: [])
      raise ArgumentError, "name must match [a-z0-9_-]+" unless NAME_PATTERN.match?(name)
      raise ArgumentError, "provider name 'openrouter' is reserved" if name == RESERVED_NAME
      raise ArgumentError, "baseUrl must start with http:// or https://" unless base_url.match?(%r{\Ahttps?://})

      now = Time.now.utc.iso8601
      @db.connection.execute(
        "INSERT INTO providers (name, base_url, api_key, models, created_at) VALUES (?, ?, ?, ?, ?)",
        [name, base_url, api_key, JSON.generate(models), now]
      )

      { "name" => name, "baseUrl" => base_url, "apiKey" => api_key, "models" => models }
    end

    # Deletes a provider by name. Returns true if a row was removed, false when unknown.
    sig { params(name: String).returns(T::Boolean) }
    def delete(name)
      @db.connection.execute("DELETE FROM providers WHERE name = ?", [name])
      @db.connection.changes.positive?
    end

    private

    sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def row_to_h(row)
      {
        "name" => row["name"],
        "baseUrl" => row["base_url"],
        "apiKey" => row["api_key"],
        "models" => JSON.parse(row["models"])
      }
    end
  end
end
