# typed: true
# frozen_string_literal: true

require "securerandom"
require "sorbet-runtime"

module RelayDaemon
  module RuntimeEnvironment
    extend T::Sig

    sig do
      params(
        source: T::Hash[String, String],
        home: String,
        token_generator: T.proc.returns(String)
      ).returns(T::Hash[String, String])
    end
    def self.prepare(source, home: Dir.home, token_generator: -> { SecureRandom.hex(32) })
      env = source.dup
      internal_token = present(env["RELAY_INTERNAL_TOKEN"]) || token_generator.call
      env["RELAY_INTERNAL_TOKEN"] = internal_token
      env["RELAY_ROUTING_CONFIG"] = present(env["RELAY_ROUTING_CONFIG"]) ||
        File.join(home, ".relay", "routing.json")

      sink_url = present(env["RELAY_LLM_CALL_SINK_URL"])
      sink_token = present(env["RELAY_LLM_CALL_SINK_TOKEN"])
      if sink_url.nil? != sink_token.nil?
        raise ArgumentError, "RELAY_LLM_CALL_SINK_URL and RELAY_LLM_CALL_SINK_TOKEN must be set together"
      end

      if sink_url.nil?
        port = present(env["RELAY_DAEMON_PORT"]) || "7777"
        env["RELAY_LLM_CALL_SINK_URL"] = "http://127.0.0.1:#{port}/internal/llm-calls"
        env["RELAY_LLM_CALL_SINK_TOKEN"] = internal_token
      end

      env
    end

    sig { params(value: T.nilable(String)).returns(T.nilable(String)) }
    def self.present(value)
      return nil if value.nil? || value.strip.empty?

      value
    end

    private_class_method :present
  end
end
