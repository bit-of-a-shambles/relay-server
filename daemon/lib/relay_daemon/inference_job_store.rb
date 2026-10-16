# typed: false
# frozen_string_literal: true
require "time"
require_relative "session_store"

module RelayDaemon
  class InferenceJobStore
    STATUSES = %w[queued in_progress completed failed cancelled interrupted].freeze
    def initialize(db)
      @db = db
    end

    def record(data)
      keys = %w[responseId sessionId runId status]
      raise ArgumentError, "inference job fields are required" unless data.is_a?(Hash) && keys.all? { |key| data[key].is_a?(String) && !data[key].empty? }
      raise ArgumentError, "unknown inference status" unless STATUSES.include?(data["status"])

      existing = @db.connection.get_first_row("SELECT session_id, run_id FROM inference_jobs WHERE response_id = ?", [data["responseId"]])
      if existing && (existing["session_id"] != data["sessionId"] || existing["run_id"] != data["runId"])
        raise ArgumentError, "inference job belongs to a different run"
      end
      @db.connection.execute("INSERT INTO inference_jobs (response_id, session_id, run_id, status, updated_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(response_id) DO UPDATE SET status = excluded.status, updated_at = excluded.updated_at",
        [data["responseId"], data["sessionId"], data["runId"], data["status"], Time.now.utc.iso8601])
      list(data["sessionId"]).find { |job| job["responseId"] == data["responseId"] }
    end

    def list(session_id)
      @db.connection.execute("SELECT * FROM inference_jobs WHERE session_id = ? ORDER BY updated_at, response_id", [session_id]).map do |row|
        { "responseId" => row["response_id"], "sessionId" => row["session_id"], "runId" => row["run_id"], "status" => row["status"], "updatedAt" => row["updated_at"] }
      end
    end

    def recover!
      sessions = SessionStore.new(@db)
      @db.connection.execute("SELECT * FROM inference_jobs WHERE status IN ('queued', 'in_progress')").each do |row|
        record({ "responseId" => row["response_id"], "sessionId" => row["session_id"], "runId" => row["run_id"], "status" => "interrupted" })
        MessageStore.new(@db, sessions).append(session_id: row["session_id"], role: "assistant", agent_run_id: row["run_id"],
          content: "Async inference was interrupted by a daemon restart. The provider may still finish the queued request. Send a new message to continue; tools were not replayed.")
      end
    end
  end
end
