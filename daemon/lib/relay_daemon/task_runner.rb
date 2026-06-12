# typed: false
# frozen_string_literal: true

require "fileutils"
require "time"
require "sorbet-runtime"
require_relative "db"
require_relative "event_bus"
require_relative "git"
require_relative "task_store"

module RelayDaemon
  class TaskRunner
    extend T::Sig

    # Builds the argv array from the command template, substituting {prompt}.
    sig { params(command_template: String, prompt: String).returns(T::Array[String]) }
    def self.build_argv(command_template, prompt)
      command_template.split.map { |arg| arg == "{prompt}" ? prompt : arg }
    end

    # Spawns the agent in a background thread that owns its own DB connection.
    # The thread transitions status queued→running, streams agent output to
    # the log (publishing one agent.event per line), auto-commits leftover
    # changes, runs the repo's test command (if any), then finishes the task
    # as needs_review/failed with aggregated costs. Publishes task.started,
    # agent.event, task.needs_review / task.finished, and stats.updated.
    sig do
      params(
        task_id: String,
        worktree_path: String,
        log_path: String,
        agent_argv: T::Array[String],
        db_path: String,
        event_bus: EventBus,
        test_command: T.nilable(String),
        agent_env: T::Hash[String, String]
      ).returns(Thread)
    end
    def self.run_async(task_id:, worktree_path:, log_path:, agent_argv:, db_path:, event_bus:, test_command: nil, agent_env: {})
      Thread.new do
        db = Db.new(db_path)
        ts = TaskStore.new(db)

        ts.update_status(task_id, "running")
        event_bus.publish(type: "task.started", task_id: task_id)

        FileUtils.mkdir_p(File.dirname(log_path))
        reader, writer = IO.pipe
        pid = Process.spawn(agent_env, *agent_argv, out: writer, err: writer, chdir: worktree_path)
        writer.close

        File.open(log_path, "w") do |log|
          reader.each_line do |line|
            log.write(line)
            event_bus.publish(type: "agent.event", task_id: task_id, payload: { "line" => line.chomp })
          end
        end
        reader.close
        _, agent_status = Process.wait2(pid)

        git = Git.new(worktree_path)
        git.commit_all("relay: task #{task_id} result")

        tests_passed = nil
        if agent_status.success? && test_command
          tpid = Process.spawn(
            "sh", "-c", test_command,
            out: [log_path, "a"], err: [:child, :out], chdir: worktree_path
          )
          _, test_status = Process.wait2(tpid)
          tests_passed = test_status.success? ? 1 : 0
        end

        final = agent_status.success? ? "needs_review" : "failed"
        ts.finish(task_id, status: final, tests_passed: tests_passed)

        if final == "needs_review"
          event_bus.publish(type: "task.needs_review", task_id: task_id,
                            payload: { "testsPassed" => tests_passed.nil? ? nil : tests_passed == 1 })
        else
          event_bus.publish(type: "task.finished", task_id: task_id, payload: { "status" => "failed" })
        end
        event_bus.publish(type: "stats.updated", task_id: task_id)

        db.connection.close
      end
    end
  end
end
