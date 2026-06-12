# typed: true
# frozen_string_literal: true

require "securerandom"
require "time"
require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  class TaskStore
    extend T::Sig

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    sig do
      params(
        repo_id: Integer,
        prompt: String,
        quality_dial: Integer,
        branch: String,
        base_commit: T.nilable(String),
        base_branch: T.nilable(String),
        id: T.nilable(String)
      ).returns(T::Hash[String, T.untyped])
    end
    def create(repo_id:, prompt:, quality_dial:, branch:, base_commit: nil, base_branch: nil, id: nil)
      id  = id || SecureRandom.uuid
      now = Time.now.utc.iso8601

      @db.connection.execute(
        "INSERT INTO tasks (id, repo_id, prompt, quality_dial, status, branch, base_commit, base_branch, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, repo_id, prompt, quality_dial, "queued", branch, base_commit, base_branch, now]
      )

      T.must(find(id))
    end

    sig { params(id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def find(id)
      row = @db.connection.get_first_row(
        "SELECT id, repo_id, prompt, quality_dial, status, branch, base_commit, base_branch,
                created_at, finished_at, tests_passed, cost_usd, frontier_cost_usd
         FROM tasks WHERE id = ?",
        [id]
      )
      row ? row_to_h(row) : nil
    end

    sig { params(id: String, status: String, finished_at: T.nilable(String)).void }
    def update_status(id, status, finished_at: nil)
      if finished_at
        @db.connection.execute(
          "UPDATE tasks SET status = ?, finished_at = ? WHERE id = ?",
          [status, finished_at, id]
        )
      else
        @db.connection.execute("UPDATE tasks SET status = ? WHERE id = ?", [status, id])
      end
    end

    # Marks a task finished: sets status, finished_at, tests_passed (1/0/nil),
    # and aggregates cost_usd / frontier_cost_usd from llm_calls for this task.
    sig { params(id: String, status: String, tests_passed: T.nilable(Integer)).void }
    def finish(id, status:, tests_passed: nil)
      # An aggregate query always returns exactly one row (NULL sums when empty).
      sums = T.must(@db.connection.get_first_row(
        "SELECT SUM(cost_usd) AS cost, SUM(frontier_cost_usd) AS frontier
         FROM llm_calls WHERE task_id = ?",
        [id]
      ))

      @db.connection.execute(
        "UPDATE tasks SET status = ?, finished_at = ?, tests_passed = ?,
                cost_usd = ?, frontier_cost_usd = ?
         WHERE id = ?",
        [status, Time.now.utc.iso8601, tests_passed,
         sums["cost"], sums["frontier"], id]
      )
    end

    private

    sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def row_to_h(row)
      cost     = row["cost_usd"]
      frontier = row["frontier_cost_usd"]
      saved    = cost && frontier ? (frontier - cost).round(6) : nil
      {
        "id"          => row["id"],
        "repoId"      => row["repo_id"],
        "prompt"      => row["prompt"],
        "qualityDial" => row["quality_dial"],
        "status"      => row["status"],
        "branch"      => row["branch"],
        "baseCommit"  => row["base_commit"],
        "baseBranch"  => row["base_branch"],
        "createdAt"   => row["created_at"],
        "finishedAt"  => row["finished_at"],
        "testsPassed" => row["tests_passed"].nil? ? nil : row["tests_passed"] == 1,
        "costUsd"     => cost,
        "savedUsd"    => saved
      }
    end
  end
end
