# typed: true
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  # Daemon-wide tool-permission approval mode (M87): whether the agent's
  # shell/tool calls are auto-approved, only escalated when they look
  # sensitive, or always escalated for a live decision.
  class ApprovalSettingsStore
    extend T::Sig

    FULL_AUTO = "full_auto"
    ASK_ON_SENSITIVE = "ask_on_sensitive"
    ASK_EVERY_TIME = "ask_every_time"
    MODES = T.let([FULL_AUTO, ASK_ON_SENSITIVE, ASK_EVERY_TIME].freeze, T::Array[String])
    DEFAULT_MODE = T.let(ASK_ON_SENSITIVE, String)

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    sig { returns(String) }
    def mode
      row = @db.connection.get_first_row("SELECT approval_mode FROM daemon_settings WHERE id = 1")
      row.nil? ? DEFAULT_MODE : row.fetch("approval_mode")
    end

    sig { params(mode: String).void }
    def update_mode!(mode)
      raise ArgumentError, "invalid approval mode: #{mode}" unless MODES.include?(mode)

      @db.connection.execute("UPDATE daemon_settings SET approval_mode = ? WHERE id = 1", [mode])
    end
  end
end
