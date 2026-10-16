# typed: true
# frozen_string_literal: true

require "shellwords"
require "sorbet-runtime"

module RelayDaemon
  # Claude-specific launch policy. SessionRunner owns process lifecycle and
  # normalized Relay events; other harness adapters must not inherit these flags.
  class ClaudeAdapter
    extend T::Sig

    sig { params(command_template: String, prompt: String, session_id: String, resume: T::Boolean).returns(T::Array[String]) }
    def self.build_argv(command_template, prompt, session_id:, resume:)
      argv = Shellwords.split(command_template).map { |arg| arg == "{prompt}" ? prompt : arg }
      resume ? argv + ["--resume", session_id] : argv + ["--session-id", session_id]
    end

    sig { params(argv: T::Array[String], enabled: T::Boolean).returns(T::Array[String]) }
    def self.streaming(argv, enabled:)
      return argv unless enabled && File.basename(argv.fetch(0, "")) == "claude"
      return argv if argv.any? { |argument| argument == "--output-format" || argument.start_with?("--output-format=") }

      argv + ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
    end

    sig { params(argv: T::Array[String], settings_path: String).returns(T::Array[String]) }
    def self.permission_hook(argv, settings_path:)
      return argv unless File.basename(argv.fetch(0, "")) == "claude"

      argv + ["--settings", settings_path]
    end
  end
end
