# typed: true
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  class LlmCallStore
    extend T::Sig

    REQUIRED_FIELDS = T.let(
      %w[requestedModel routedModel tier promptTokens completionTokens
         frontierCostUsd latencyMs status createdAt].freeze,
      T::Array[String]
    )

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    # Insert a call record. Returns the new row id on success,
    # or raises ArgumentError listing missing/invalid fields.
    sig { params(data: T::Hash[String, T.untyped]).returns(Integer) }
    def insert(data)
      missing = REQUIRED_FIELDS.reject { |f| data.key?(f) && !data[f].nil? }
      raise ArgumentError, "missing fields: #{missing.join(', ')}" unless missing.empty?

      @db.connection.execute(
        <<~SQL,
          INSERT INTO llm_calls
            (task_id, session_id, run_id, requested_model, route_target, routed_model, provider, tier,
             prompt_tokens, completion_tokens, cost_usd, frontier_cost_usd,
             latency_ms, escalation_reason, status, error_message, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          nil,
          data["sessionId"],
          data["runId"],
          data["requestedModel"],
          data["routeTarget"] || data["routedModel"],
          data["routedModel"],
          data["provider"],
          data["tier"].to_i,
          data["promptTokens"].to_i,
          data["completionTokens"].to_i,
          data["costUsd"],
          data["frontierCostUsd"].to_f,
          data["latencyMs"].to_i,
          data["escalationReason"],
          data["status"],
          data["errorMessage"],
          data["createdAt"]
        ]
      )
      @db.connection.last_insert_row_id
    end
  end
end
