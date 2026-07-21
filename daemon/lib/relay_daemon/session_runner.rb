# typed: false
# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "sorbet-runtime"
require_relative "db"
require_relative "event_bus"
require_relative "push_notifier"
require_relative "session_store"

module RelayDaemon
  class SessionRunner
    extend T::Sig

    @locks_mutex = Mutex.new
    @locks = {}
    @busy = {}

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
          agent_command: T.any(String, T::Array[String]),
          db_path: String,
          event_bus: EventBus,
          agent_env: T::Hash[String, String],
          router_base_url: T.nilable(String),
          run_id: T.nilable(String),
          append_user: T::Boolean,
          resume: T.nilable(T::Boolean),
          escalated: T::Boolean,
          push_notifier: T.nilable(PushNotifier),
          reserved: T::Boolean
        ).returns(Thread)
      end
      def run_async(session_id:, content:, worktree_path:, sessions_log_dir:, agent_command:, db_path:, event_bus:, agent_env: {}, router_base_url: nil, run_id: nil, append_user: true, resume: nil, escalated: false, push_notifier: nil, reserved: false)
        reserve(session_id) unless reserved
        Thread.new do
          begin
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
                router_base_url: router_base_url,
                run_id: run_id,
                append_user: append_user,
                resume: resume,
                escalated: escalated,
                push_notifier: push_notifier
              )
            end
          ensure
            release(session_id)
          end
        end
      end

      sig { params(session_id: String).void }
      def reserve(session_id)
        @locks_mutex.synchronize { @busy[session_id] = @busy.fetch(session_id, 0) + 1 }
      end

      sig { params(session_id: String).void }
      def release(session_id)
        @locks_mutex.synchronize do
          count = @busy.fetch(session_id, 0) - 1
          count.zero? ? @busy.delete(session_id) : @busy[session_id] = count
        end
      end

      # True while an accepted session operation is active or waiting for its
      # per-session runner lock. Used to refuse discarding a session mid-run.
      sig { params(session_id: String).returns(T::Boolean) }
      def running?(session_id)
        @locks_mutex.synchronize { @busy.fetch(session_id, 0).positive? }
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
          agent_command: T.any(String, T::Array[String]),
          db_path: String,
          event_bus: EventBus,
          agent_env: T::Hash[String, String],
          router_base_url: T.nilable(String),
          run_id: T.nilable(String),
          append_user: T::Boolean,
          resume: T.nilable(T::Boolean),
          escalated: T::Boolean,
          push_notifier: T.nilable(PushNotifier)
        ).void
      end
      def run_once(session_id:, content:, worktree_path:, sessions_log_dir:, agent_command:, db_path:, event_bus:, agent_env:, router_base_url:, run_id:, append_user:, resume:, escalated: false, push_notifier: nil)
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
        argv = agent_command.is_a?(Array) ? agent_command : build_argv(agent_command, content, session_id: session_id, resume: resume)
        run_env = agent_env.merge("RELAY_SESSION_ID" => session_id)
        if router_base_url
          base = "#{router_base_url.delete_suffix("/")}/session/#{session_id}"
          base += "/escalated" if escalated
          run_env["ANTHROPIC_BASE_URL"] = base
        end

        lines = []
        reader, writer = IO.pipe
        pid = Process.spawn(run_env, *argv, out: writer, err: writer, chdir: worktree_path)
        writer.close

        File.open(log_path, "w") do |log|
          reader.each_line do |line|
            log.write(line)
            next unless publish_agent_line?(line)

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
        updated_session = T.must(session_store.find(session_id))
        event_bus.publish(
          type: "session.updated",
          payload: {
            "sessionId" => updated_session["id"],
            "repoId" => updated_session["repoId"],
            "title" => updated_session["title"],
            "status" => updated_session["status"],
            "lastMessageAt" => updated_session["lastMessageAt"]
          }
        )
        push_notifier&.notify(PushNotifier::AGENT_FINISHED)
      ensure
        db.connection.close
      end

      sig { params(line: String).returns(T::Boolean) }
      def publish_agent_line?(line)
        normalized = line.downcase
        return false if normalized.include?("claude.ai connectors are disabled") &&
          normalized.include?("anthropic_api_key")

        true
      end
    end
  end
end
