# typed: true
# frozen_string_literal: true

require "time"
require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  # CRUD store for device tokens used by the push relay.
  class PushDeviceStore
    extend T::Sig

    DEVICE_TOKEN_PATTERN = T.let(/\A(?:[0-9a-fA-F]{2}){8,64}\z/, Regexp)

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    sig { params(limit: T.nilable(Integer)).returns(T::Array[T::Hash[String, T.untyped]]) }
    def all(limit: nil)
      sql = "SELECT device_token, created_at FROM push_devices ORDER BY created_at, device_token"
      rows = if limit.nil?
               @db.connection.execute(sql)
             else
               @db.connection.execute("#{sql} LIMIT ?", [limit])
             end
      rows.map { |row| row_to_h(row) }
    end

    sig { params(device_token: String).returns(T::Boolean) }
    def self.valid_device_token?(device_token)
      DEVICE_TOKEN_PATTERN.match?(device_token)
    end

    sig { params(device_token: String).returns(String) }
    def self.canonical_device_token(device_token)
      unless valid_device_token?(device_token)
        raise ArgumentError, "deviceToken must be 16..128 even-length hex characters"
      end

      device_token.downcase
    end

    sig { params(device_token: String).returns(T::Hash[String, T.untyped]) }
    def create(device_token:)
      device_token = self.class.canonical_device_token(device_token)

      created_at = Time.now.utc.iso8601
      @db.connection.execute(
        <<~SQL,
          INSERT INTO push_devices (device_token, created_at) VALUES (?, ?)
          ON CONFLICT(device_token) DO NOTHING
        SQL
        [device_token, created_at]
      )
      T.must(find(device_token))
    end

    sig { params(device_token: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def find(device_token)
      device_token = self.class.canonical_device_token(device_token)

      row = @db.connection.get_first_row(
        "SELECT device_token, created_at FROM push_devices WHERE device_token = ?",
        [device_token]
      )
      row.nil? ? nil : row_to_h(row)
    end

    sig { params(device_token: String).returns(T::Boolean) }
    def delete(device_token)
      device_token = self.class.canonical_device_token(device_token)

      @db.connection.execute("DELETE FROM push_devices WHERE device_token = ?", [device_token])
      @db.connection.changes.positive?
    end

    sig { returns(T::Boolean) }
    def close_current_connection
      @db.close_current_connection
    end

    private

    sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def row_to_h(row)
      { "deviceToken" => row["device_token"], "createdAt" => row["created_at"] }
    end
  end
end
