# typed: true
# frozen_string_literal: true

require "time"
require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  class Stats
    extend T::Sig

    VALID_RANGES = T.let(%w[7d 30d 90d all].freeze, T::Array[String])

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    # Returns a stats hash for the given range string.
    # Raises ArgumentError on unknown range.
    sig { params(range: String).returns(T::Hash[Symbol, T.untyped]) }
    def compute(range: "30d")
      raise ArgumentError, "invalid range: #{range}" unless VALID_RANGES.include?(range)

      cutoff = cutoff_for(range)
      call_totals = aggregate_calls(cutoff)
      per_model   = per_model_breakdown(cutoff)
      task_stats  = aggregate_tasks(cutoff)

      spend    = call_totals["spend_usd"].to_f
      frontier = call_totals["frontier_usd"].to_f
      finished = task_stats["finished"].to_i
      approved = task_stats["approved"].to_i

      {
        range: range,
        spendUsd: spend,
        frontierCostUsd: frontier,
        savedUsd: (frontier - spend).round(10),
        taskCount: task_stats["total"].to_i,
        taskSuccessRate: finished > 0 ? (approved.to_f / finished).round(6) : nil,
        perModel: per_model.map do |row|
          {
            model: row["model"],
            calls: row["calls"].to_i,
            spendUsd: row["spend_usd"].to_f,
            promptTokens: row["prompt_tokens"].to_i,
            completionTokens: row["completion_tokens"].to_i
          }
        end
      }
    end

    private

    sig { params(range: String).returns(T.nilable(String)) }
    def cutoff_for(range)
      seconds = case range
                when "7d"  then 7 * 24 * 3600
                when "30d" then 30 * 24 * 3600
                when "90d" then 90 * 24 * 3600
                else             return nil
                end
      (Time.now.utc - seconds).iso8601
    end

    sig { params(cutoff: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
    def aggregate_calls(cutoff)
      sql = <<~SQL
        SELECT COALESCE(SUM(COALESCE(cost_usd, 0)), 0)   AS spend_usd,
               COALESCE(SUM(frontier_cost_usd),       0) AS frontier_usd
        FROM llm_calls
        #{date_filter("created_at", cutoff)}
      SQL
      row = @db.connection.get_first_row(sql, cutoff ? [cutoff] : [])
      row || { "spend_usd" => 0.0, "frontier_usd" => 0.0 }
    end

    sig { params(cutoff: T.nilable(String)).returns(T::Array[T::Hash[String, T.untyped]]) }
    def per_model_breakdown(cutoff)
      sql = <<~SQL
        SELECT routed_model                                   AS model,
               COUNT(*)                                       AS calls,
               COALESCE(SUM(COALESCE(cost_usd, 0)), 0)       AS spend_usd,
               COALESCE(SUM(prompt_tokens),         0)       AS prompt_tokens,
               COALESCE(SUM(completion_tokens),     0)       AS completion_tokens
        FROM llm_calls
        #{date_filter("created_at", cutoff)}
        GROUP BY routed_model
        ORDER BY routed_model
      SQL
      @db.connection.execute(sql, cutoff ? [cutoff] : [])
    end

    sig { params(cutoff: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
    def aggregate_tasks(cutoff)
      sql = <<~SQL
        SELECT COUNT(*)                                            AS total,
               SUM(CASE WHEN status IN ('approved','rejected','failed') THEN 1 ELSE 0 END) AS finished,
               SUM(CASE WHEN status = 'approved' THEN 1 ELSE 0 END)                       AS approved
        FROM tasks
        #{date_filter("created_at", cutoff)}
      SQL
      row = @db.connection.get_first_row(sql, cutoff ? [cutoff] : [])
      row || { "total" => 0, "finished" => 0, "approved" => 0 }
    end

    sig { params(column: String, cutoff: T.nilable(String)).returns(String) }
    def date_filter(column, cutoff)
      cutoff ? "WHERE #{column} >= ?" : ""
    end
  end
end
