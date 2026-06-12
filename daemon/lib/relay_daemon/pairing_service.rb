# typed: true
# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"
require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  # Pairing codes live in daemon process memory (single-use, 5 min TTL).
  # Claimed tokens are stored in auth_tokens as SHA-256 hashes only.
  class PairingService
    extend T::Sig

    CODE_TTL_SECONDS = 300

    DEFAULT_CLOCK = T.let(-> { Time.now.utc }, T.proc.returns(Time))

    sig { params(db: Db, clock: T.proc.returns(Time)).void }
    def initialize(db, clock: DEFAULT_CLOCK)
      @db    = db
      @clock = clock
      @mutex = T.let(Mutex.new, Mutex)
      @codes = T.let({}, T::Hash[String, Time])
    end

    # Generates a single-use pairing code valid for 5 minutes.
    sig { returns(String) }
    def start_pairing
      code = SecureRandom.alphanumeric(8)
      @mutex.synchronize { @codes[code] = @clock.call + CODE_TTL_SECONDS }
      code
    end

    # Exchanges a valid pairing code for a fresh 256-bit auth token.
    # The code is consumed on first use regardless of outcome.
    # Returns nil for unknown, already-used, or expired codes.
    sig { params(code: String).returns(T.nilable(String)) }
    def claim(code)
      expired = T.let(false, T::Boolean)
      known = @mutex.synchronize do
        expires_at = @codes.delete(code)
        expired = !expires_at.nil? && @clock.call > expires_at
        !expires_at.nil?
      end
      return nil if !known || expired

      token = SecureRandom.hex(32)
      @db.connection.execute(
        "INSERT INTO auth_tokens (token_hash, created_at) VALUES (?, ?)",
        [hash_token(token), @clock.call.iso8601]
      )
      token
    end

    # True when the token's hash matches an unrevoked auth_tokens row.
    sig { params(token: String).returns(T::Boolean) }
    def token_valid?(token)
      return false if token.empty?

      row = @db.connection.get_first_value(
        "SELECT id FROM auth_tokens WHERE token_hash = ? AND revoked_at IS NULL",
        [hash_token(token)]
      )
      !row.nil?
    end

    # Revokes tokens. Accepts either the full token (hashed and matched
    # exactly) or a prefix of the stored token hash. Returns the number of
    # tokens revoked.
    sig { params(token_or_hash_prefix: String).returns(Integer) }
    def revoke(token_or_hash_prefix)
      now = @clock.call.iso8601

      @db.connection.execute(
        "UPDATE auth_tokens SET revoked_at = ? WHERE revoked_at IS NULL AND token_hash = ?",
        [now, hash_token(token_or_hash_prefix)]
      )
      count = @db.connection.changes
      return count if count.positive?

      @db.connection.execute(
        "UPDATE auth_tokens SET revoked_at = ? WHERE revoked_at IS NULL AND token_hash LIKE ?",
        [now, "#{token_or_hash_prefix}%"]
      )
      @db.connection.changes
    end

    private

    sig { params(token: String).returns(String) }
    def hash_token(token)
      Digest::SHA256.hexdigest(token)
    end
  end
end
