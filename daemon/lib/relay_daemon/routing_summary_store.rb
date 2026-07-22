# typed: true
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  class RoutingSummaryStore
    extend T::Sig

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    sig { params(session_id: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def list_for_session(session_id)
      rows = @db.connection.execute(
        <<~SQL,
          SELECT run_id, requested_model, route_target, routed_model, cost_usd,
                 escalation_reason
          FROM llm_calls
          WHERE session_id = ? AND run_id IS NOT NULL
          ORDER BY id
        SQL
        [session_id]
      )

      grouped = T.let({}, T::Hash[String, T::Array[T::Hash[String, T.untyped]]])
      rows.each do |row|
        run_id = row.fetch("run_id").to_s
        grouped[run_id] ||= []
        T.must(grouped[run_id]) << row
      end

      grouped.map do |run_id, calls|
        costs = calls.map { |call| call["cost_usd"] }
        {
          "runId" => run_id,
          "isAuto" => calls.any? { |call| call["requested_model"] == "relay-auto" },
          "routeTargets" => ordered_unique(calls, "route_target"),
          "actualModels" => ordered_unique(calls, "routed_model"),
          "callCount" => calls.length,
          "costUsd" => costs.any?(&:nil?) ? nil : costs.sum(&:to_f),
          "escalated" => calls.any? { |call| !call["escalation_reason"].to_s.empty? }
        }
      end
    end

    private

    sig do
      params(rows: T::Array[T::Hash[String, T.untyped]], key: String).returns(T::Array[String])
    end
    def ordered_unique(rows, key)
      rows.map { |row| row[key].to_s }.reject(&:empty?).uniq
    end
  end
end
