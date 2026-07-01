# typed: false
# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "sorbet-runtime"
require_relative "db"
require_relative "event_bus"
require_relative "session_store"

module RelayDaemon
  class SessionRunner
    extend T::Sig

    @locks_mutex = Mutex.new
    @locks = {}

    class << self
      extend T::Sig

      sig { params(command_template: String, prompt: String, session_id: String, resume: T::Boolean).returns(T::Array[String]) }
      def build_argv(command_template, prompt, session_id:, resume:)
        argv = command_template.split.map { |arg| arg == "{prompt}" ? prompt : arg }
        resume ? argv + ["--resume", session_id] : argv + ["--session-id", session_id]
      end

      sig do
        params(
          session_id: String,
          content: String,
          worktree_path: String,
          sessions_log_dir: String,
          agent_command: String,
          db_path: String,
          event_bus: EventBus,
          agent_env: T::Hash[String, String],
          run_id: T.nilable(String),
          append_user: T::Boolean,
          resume: T.nilable(T::Boolean)
        ).returns(Thread)
      end
      def run_async(session_id:, content:, worktree_path:, sessions_log_dir:, agent_command:, db_path:, event_bus:, agent_env: {}, run_id: nil, append_user: true, resume: nil)
        Thread.new do
          lock_for(session_id).synchronize do
            run_once(
              session_id: session_id,
              content: content,
              worktree_path: worktree_path,
              sessions_log_dir: sessions_log_dir,
              agent_command: agent_command,
              db_path: db_path,
              event_bus: event_bus,
              agent_env: agent_env,
              run_id: run_id,
              append_user: append_user,
              resume: resume
            )
          end
        end
      end

      private

      sig { params(session_id: String).returns(Mutex) }
      def lock_for(session_id)
        @locks_mutex.synchronize do
          @locks[session_id] ||= Mutex.new
        end
      end

      sig do
        params(
          session_id: String,
          content: String,
          worktree_path: String,
          sessions_log_dir: String,
          agent_command: String,
          db_path: String,
          event_bus: EventBus,
          agent_env: T::Hash[String, String],
          run_id: T.nilable(String),
          append_user: T::Boolean,
          resume: T.nilable(T::Boolean)
        ).void
      end
      def run_once(session_id:, content:, worktree_path:, sessions_log_dir:, agent_command:, db_path:, event_bus:, agent_env:, run_id:, append_user:, resume:)
        run_id ||= SecureRandom.uuid
        db = Db.new(db_path)
        session_store = SessionStore.new(db)
        message_store = MessageStore.new(db, session_store)
        resume = !message_store.list_for_session(session_id).empty? if resume.nil?

        if append_user
          message_store.append(session_id: session_id, role: "user", content: content, agent_run_id: run_id)
        end

        run_dir = File.join(sessions_log_dir, session_id, "runs")
        FileUtils.mkdir_p(run_dir)
        log_path = File.join(run_dir, "#{run_id}.log")
        argv = build_argv(agent_command, content, session_id: session_id, resume: resume)

        lines = []
        reader, writer = IO.pipe
        pid = Process.spawn(agent_env, *argv, out: writer, err: writer, chdir: worktree_path)
        writer.close

        File.open(log_path, "w") do |log|
          reader.each_line do |line|
            log.write(line)
            lines << line
            event_bus.publish(
              type: "agent.event",
              payload: { "sessionId" => session_id, "agentRunId" => run_id, "line" => line.chomp }
            )
          end
        end
        reader.close
        _, status = Process.wait2(pid)

        assistant_content = lines.join.strip
        if assistant_content.empty?
          assistant_content = "Agent exited with status #{status.exitstatus}"
        end

        message_store.append(
          session_id: session_id,
          role: "assistant",
          content: assistant_content,
          agent_run_id: run_id
        )
      ensure
        db.connection.close
      end
    end
  end
end
