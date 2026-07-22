# typed: true
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  # Reads the proprietary eval dataset: every routed model call joined to the
  # task or chat session whose tests verify it. For sessions, a call is
  # attributed to the first session test run recorded after the call.
  class EvalStore
    extend T::Sig

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    # Per routed-model rollup of test-verified outcomes. Outcome-verified routing
    # uses this to prefer the cheapest model that historically passes tests.
    # `passRate` is passed tests over outcomes that actually ran tests
    # (nil when none did), counted over distinct session test outcomes.
    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def model_outcomes
      sql = <<~SQL
        SELECT route_target                                                        AS model,
               COUNT(*)                                                            AS calls,
               COUNT(DISTINCT outcome_id)                                          AS outcomes,
               COUNT(DISTINCT CASE WHEN tests_passed IS NOT NULL THEN outcome_id END) AS outcomes_with_tests,
               COUNT(DISTINCT CASE WHEN tests_passed = 1 THEN outcome_id END)      AS outcomes_passed,
               COALESCE(SUM(COALESCE(cost_usd, 0)), 0)                             AS spend_usd
        FROM eval_dataset
        GROUP BY route_target
        ORDER BY route_target
      SQL

      @db.connection.execute(sql).map do |row|
        with_tests = row["outcomes_with_tests"].to_i
        passed     = row["outcomes_passed"].to_i
        {
          model:          row["model"],
          calls:          row["calls"].to_i,
          outcomes:       row["outcomes"].to_i,
          outcomesWithTests: with_tests,
          outcomesPassed: passed,
          passRate:       with_tests.positive? ? (passed.to_f / with_tests).round(6) : nil,
          spendUsd:       row["spend_usd"].to_f
        }
      end
    end
  end
end
