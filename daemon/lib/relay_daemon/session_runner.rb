# typed: false
# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "sorbet-runtime"
require_relative "db"
require_relative "claude_adapter"
require_relative "event_bus"
require_relative "push_notifier"
require_relative "session_store"

module RelayDaemon
  class SessionRunner
    extend T::Sig

    DEFAULT_RUN_TIMEOUT_SECONDS = T.let(600, Integer)
    DEFAULT_KILL_GRACE_SECONDS = T.let(5, Integer)
    PERMISSION_HOOK_SCRIPT_PATH = T.let(File.expand_path("../../bin/permission_hook", __dir__), String)

    @locks_mutex = Mutex.new
    @locks = {}
    @busy = {}
    @running_mutex = Mutex.new
    @running_pids = {}
    @stop_requested = {}

    class << self
      extend T::Sig

      sig { params(command_template: String, prompt: String, session_id: String, resume: T::Boolean).returns(T::Array[String]) }
      def build_argv(command_template, prompt, session_id:, resume:)
        ClaudeAdapter.build_argv(command_template, prompt, session_id: session_id, resume: resume)
      end

      sig { params(argv: T::Array[String], enabled: T::Boolean).returns(T::Array[String]) }
      def enable_claude_streaming(argv, enabled:)
        ClaudeAdapter.streaming(argv, enabled: enabled)
      end

      sig { params(argv: T::Array[String], settings_path: String).returns(T::Array[String]) }
      def enable_permission_hook(argv, settings_path:)
        ClaudeAdapter.permission_hook(argv, settings_path: settings_path)
      end

      # Writes the PreToolUse hook settings file consumed by
      # enable_permission_hook. Every Bash tool call routes through
      # permission_hook.rb, which decides allow/deny by calling back into
      # this same daemon (see ToolSensitivityClassifier, ApprovalSettingsStore).
      sig { params(path: String).void }
      def write_permission_hook_settings!(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate(
          "hooks" => {
            "PreToolUse" => [
              {
                "matcher" => "Bash",
                "hooks" => [{ "type" => "command", "command" => "ruby #{PERMISSION_HOOK_SCRIPT_PATH}" }]
              }
            ]
          }
        ))
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
          reserved: T::Boolean,
          run_timeout_seconds: Numeric,
          kill_grace_seconds: Numeric
        ).returns(Thread)
      end
      def run_async(session_id:, content:, worktree_path:, sessions_log_dir:, agent_command:, db_path:, event_bus:, agent_env: {}, router_base_url: nil, run_id: nil, append_user: true, resume: nil, escalated: false, push_notifier: nil, reserved: false, run_timeout_seconds: DEFAULT_RUN_TIMEOUT_SECONDS, kill_grace_seconds: DEFAULT_KILL_GRACE_SECONDS)
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
                push_notifier: push_notifier,
                run_timeout_seconds: run_timeout_seconds,
                kill_grace_seconds: kill_grace_seconds
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

      # Cancels the agent process currently running for session_id, if any
      # (a live TERM, escalating to KILL after kill_grace_seconds if the
      # process ignores it — same escalation the run-timeout watchdog uses).
      # Returns false when no run is in progress for this session, so the
      # caller can report "nothing to stop" instead of a false success.
      sig { params(session_id: String, kill_grace_seconds: Numeric).returns(T::Boolean) }
      def stop(session_id, kill_grace_seconds: DEFAULT_KILL_GRACE_SECONDS)
        pid = @running_mutex.synchronize do
          next nil unless @running_pids.key?(session_id)

          @stop_requested[session_id] = true
          @running_pids[session_id]
        end
        return false if pid.nil?

        signal_process_group(pid, "TERM")
        Thread.new do
          sleep(kill_grace_seconds)
          still_running = @running_mutex.synchronize { @running_pids[session_id] == pid }
          signal_process_group(pid, "KILL") if still_running
        end
        true
      end

      private

      sig { params(session_id: String, pid: Integer).void }
      def register_running(session_id, pid)
        @running_mutex.synchronize { @running_pids[session_id] = pid }
      end

      sig { params(session_id: String).returns(T::Boolean) }
      def unregister_running(session_id)
        @running_mutex.synchronize do
          stopped = @stop_requested.delete(session_id) || false
          @running_pids.delete(session_id)
          stopped
        end
      end

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
          push_notifier: T.nilable(PushNotifier),
          run_timeout_seconds: Numeric,
          kill_grace_seconds: Numeric
        ).void
      end
      def run_once(session_id:, content:, worktree_path:, sessions_log_dir:, agent_command:, db_path:, event_bus:, agent_env:, router_base_url:, run_id:, append_user:, resume:, escalated: false, push_notifier: nil, run_timeout_seconds: DEFAULT_RUN_TIMEOUT_SECONDS, kill_grace_seconds: DEFAULT_KILL_GRACE_SECONDS)
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
        run_env = agent_env.merge("RELAY_SESSION_ID" => session_id, "RELAY_AGENT_RUN_ID" => run_id)
        if router_base_url
          base = "#{router_base_url.delete_suffix("/")}/session/#{session_id}/run/#{run_id}"
          base += "/escalated" if escalated
          run_env["ANTHROPIC_BASE_URL"] = base
        end

        plain_lines = []
        preview_content = ""
        final_assistant_content = nil
        final_result_content = nil
        sequence = 0
        stream_json = stream_json_argv?(argv)
        stdin_reader, stdin_writer = IO.pipe
        stdout_reader, stdout_writer = IO.pipe
        stderr_reader, stderr_writer = IO.pipe
        pid = Process.spawn(run_env, *argv, in: stdin_reader, out: stdout_writer, err: stderr_writer, chdir: worktree_path, pgroup: true)
        register_running(session_id, pid)
        stdin_reader.close
        # Close the child's stdin immediately: Relay never answers tool prompts
        # through it. M87's permission protocol is out-of-band -- the CLI's
        # PreToolUse hook calls back into the daemon over HTTP (see
        # enable_permission_hook) -- so any prompt that still tries to read stdin
        # should get an immediate EOF here rather than hang on the daemon's own
        # inherited terminal/service stdin.
        stdin_writer.close
        stdout_writer.close
        stderr_writer.close

        timed_out = false
        watchdog_mutex = Mutex.new
        watchdog_activity = ConditionVariable.new
        watchdog_finished = false
        # Idle watchdog: the deadline resets every time the agent writes a
        # line, so an actively streaming run stays alive indefinitely and only
        # run_timeout_seconds of total silence (a blocked prompt, a hung tool,
        # a dead upstream) stops the run.
        last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        watchdog = Thread.new do
          action = nil
          until action
            action = watchdog_mutex.synchronize do
              if watchdog_finished
                :stop
              elsif (last_activity + run_timeout_seconds) <= Process.clock_gettime(Process::CLOCK_MONOTONIC)
                timed_out = true
                :timeout
              else
                remaining = (last_activity + run_timeout_seconds) - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                watchdog_activity.wait(watchdog_mutex, remaining)
                nil
              end
            end
          end

          if action == :timeout
            signal_process_group(pid, "TERM")
            # Ends early when the main thread signals after reaping the
            # child; otherwise the full grace elapses before SIGKILL.
            watchdog_mutex.synchronize { watchdog_activity.wait(watchdog_mutex, kill_grace_seconds) }
            signal_process_group(pid, "KILL")
          end
        end

        File.open(log_path, "w") do |log|
          log_mutex = Mutex.new
          stderr_thread = Thread.new do
            stderr_reader.each_line do |line|
              log_mutex.synchronize { log.write(line); log.flush }
              watchdog_mutex.synchronize do
                last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                watchdog_activity.signal
              end
              publish_agent_line(event_bus, session_id, run_id, line)
            end
          end

          stdout_reader.each_line do |line|
            log_mutex.synchronize { log.write(line); log.flush }
            watchdog_mutex.synchronize do
              last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              watchdog_activity.signal
            end
            if stream_json
              parsed = parse_agent_line(line)
              case parsed["kind"]
              when "delta"
                delta = T.must(parsed["text"])
                preview_content += delta
                event_bus.publish(
                  type: "assistant.updated",
                  payload: {
                    "sessionId" => session_id,
                    "agentRunId" => run_id,
                    "sequence" => sequence,
                    "content" => preview_content
                  }
                )
                sequence += 1
              when "final_assistant"
                final_assistant_content = T.must(parsed["text"])
              when "final_result"
                final_result_content = T.must(parsed["text"])
              when "plain"
                if publish_agent_line?(line)
                  plain_lines << line
                  publish_agent_line(event_bus, session_id, run_id, line)
                end
              end
            else
              if publish_agent_line?(line)
                plain_lines << line
                publish_agent_line(event_bus, session_id, run_id, line)
              end
            end
          end
          stdout_reader.close
          stderr_thread.join
          stderr_reader.close
        end
        _, status = Process.wait2(pid)
        watchdog_mutex.synchronize do
          watchdog_finished = true
          watchdog_activity.signal
        end
        watchdog.join
        timed_out = watchdog_mutex.synchronize { timed_out }
        stopped_by_user = unregister_running(session_id)

        assistant_content = if timed_out
                              "Relay stopped this run after #{run_timeout_seconds}s with no response — " \
                                "the agent may be stuck or waiting on a prompt Relay can't answer " \
                                "automatically."
                            elsif stopped_by_user
                              "Stopped — this run was cancelled from the app."
                            elsif final_result_content && !final_result_content.empty?
                              final_result_content.strip
                            elsif final_assistant_content && !final_assistant_content.empty?
                              final_assistant_content.strip
                            elsif !preview_content.empty?
                              preview_content
                            else
                              plain_lines.join.strip
                            end
        if assistant_content.empty?
          assistant_content = "Agent exited with status #{status.exitstatus}"
        end

        assistant_message = message_store.append(
          session_id: session_id,
          role: "assistant",
          content: assistant_content,
          agent_run_id: run_id
        )
        event_bus.publish(
          type: "message.created",
          payload: { "sessionId" => session_id, "message" => assistant_message }
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
        unregister_running(session_id)
        db.connection.close
      end

      sig { params(pid: Integer, sig_name: String).void }
      def signal_process_group(pid, sig_name)
        Process.kill(sig_name, -pid)
      rescue Errno::ESRCH
        # Process group already exited.
      end

      sig { params(line: String).returns(T::Boolean) }
      def publish_agent_line?(line)
        # This CLI diagnostic is expected for Relay's router alias. Preserve
        # it in the native run log, while genuine model failures still surface.
        return false if line.start_with?("[claude-code:unrecognized_model]") &&
          line.match?(/"model"\s*:\s*"relay-auto"/)
        normalized = line.downcase
        return false if normalized.include?("claude.ai connectors are disabled") &&
          normalized.include?("anthropic_api_key")

        true
      end

      sig do
        params(event_bus: EventBus, session_id: String, run_id: String, line: String).void
      end
      def publish_agent_line(event_bus, session_id, run_id, line)
        return unless publish_agent_line?(line)

        event_bus.publish(
          type: "agent.event",
          payload: { "sessionId" => session_id, "agentRunId" => run_id, "line" => line.chomp }
        )
      end

      sig { params(argv: T::Array[String]).returns(T::Boolean) }
      def stream_json_argv?(argv)
        argv.each_with_index.any? do |arg, index|
          arg == "--output-format=stream-json" ||
            (arg == "--output-format" && argv[index + 1] == "stream-json")
        end
      end

      sig { params(line: String).returns(T::Hash[String, T.untyped]) }
      def parse_agent_line(line)
        raw = line.chomp
        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          { "kind" => "plain" }
        end
        return { "kind" => "plain" } unless parsed.is_a?(Hash)

        delta = parse_delta(parsed)
        return { "kind" => "delta", "text" => delta } if delta

        assistant = parse_final_assistant(parsed)
        return { "kind" => "final_assistant", "text" => assistant } if assistant

        result = parse_final_result(parsed)
        return { "kind" => "final_result", "text" => result } if result

        return { "kind" => "protocol" } if protocol_event?(parsed)

        { "kind" => "plain" }
      end

      sig { params(event: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
      def parse_delta(event)
        return nil unless event["type"] == "stream_event"

        content_event = event["event"]
        return nil unless content_event.is_a?(Hash) && content_event["type"] == "content_block_delta"
        return nil unless event["parent_tool_use_id"].nil? && content_event["parent_tool_use_id"].nil?

        delta = content_event["delta"]
        return nil unless delta.is_a?(Hash) && delta["type"] == "text_delta"
        return nil unless delta["parent_tool_use_id"].nil?

        text = delta["text"]
        text.is_a?(String) && !text.empty? ? text : nil
      end

      sig { params(event: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
      def parse_final_assistant(event)
        return nil unless event["type"] == "assistant"
        return nil unless event["parent_tool_use_id"].nil?

        message = event["message"]
        content = if message.is_a?(Hash) && message["content"].is_a?(Array)
                    message["content"]
                  else
                    event["content"]
                  end
        return nil unless content.is_a?(Array)

        blocks = content.filter_map do |block|
          next unless block.is_a?(Hash) && block["type"] == "text"

          block["text"] if block["text"].is_a?(String)
        end
        text = join_text_blocks(blocks)
        text.empty? ? nil : text
      end

      sig { params(blocks: T::Array[String]).returns(String) }
      def join_text_blocks(blocks)
        blocks.reduce("") do |joined, block|
          next block if joined.empty?
          next joined if block.empty?

          boundary_has_space = joined.end_with?(" ", "\n", "\t") || block.start_with?(" ", "\n", "\t")
          joined + (boundary_has_space ? "" : " ") + block
        end
      end

      sig { params(event: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
      def parse_final_result(event)
        return nil unless event["type"] == "result"

        result = event["result"]
        return result if result.is_a?(String) && !result.empty?

        errors = event["errors"]
        return nil unless event["is_error"] == true && errors.is_a?(Array)

        messages = errors.grep(String).reject(&:empty?)
        messages.empty? ? nil : "Agent failed: #{messages.join("\n") }"
      end

      sig { params(event: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def protocol_event?(event)
        %w[assistant content_block_delta result stream_event system tool tool_result tool_use user].include?(event["type"])
      end
    end
  end
end
