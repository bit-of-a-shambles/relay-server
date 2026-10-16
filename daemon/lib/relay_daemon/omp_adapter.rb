# typed: false
# frozen_string_literal: true
require "json"
require "fileutils"

module RelayDaemon
  class OmpAdapter
    def self.command(executable:, provider:, router_base:, model:, native_id:, mode:, session_dir:)
      raise ArgumentError, "Oh My Pi RPC requires explicitly selected full_auto mode" unless mode == "full_auto"

      FileUtils.mkdir_p(session_dir, mode: 0o700)
      command = [executable, "--mode", "rpc", "--approval-mode", "yolo", "--session-dir", session_dir, "--no-title"]
      command += ["--resume", native_id] if native_id
      selected = provider == "native" ? model : "relay/#{model}"
      command += ["--model", selected] unless selected.empty?
      command
    end

    def self.environment(provider:, router_base:, model:, session_dir:)
      return {} if provider == "native"

      directory = File.join(session_dir, "agent")
      FileUtils.mkdir_p(directory, mode: 0o700)
      config = { "providers" => { "relay" => { "baseUrl" => "#{router_base}/v1", "api" => "openai-completions", "apiKey" => "RELAY_UPSTREAM_KEY",
        "models" => [{ "id" => model, "name" => model, "contextWindow" => 32768, "maxTokens" => 4096 }] } } }
      File.write(File.join(directory, "models.yml"), JSON.generate(config), mode: "w", perm: 0o600)
      { "PI_CODING_AGENT_DIR" => directory, "RELAY_UPSTREAM_KEY" => "relay-dummy" }
    end

    def run(reader:, writer:, content:, native_id:, model:, mode:, persist:, emit:, decide:)
      send_command = ->(value) { writer.puts(JSON.generate(value)); writer.flush }
      text = ""
      completed = false
      reader.each_line do |line|
        event = JSON.parse(line)
        raise IOError, "Oh My Pi request failed; check Mac sign-in and model access" if event["success"] == false || event["type"] == "rpc_frame_error"

        case event["type"]
        when "ready"
          send_command.call({ "id" => "turn", "type" => "prompt", "message" => content })
        when "message_update"
          delta = event["assistantMessageEvent"]
          next unless delta && delta["type"] == "text_delta"

          text += delta.fetch("delta")
          emit.call({ "type" => "stream_event", "event" => { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => delta.fetch("delta") } } })
        when "prompt_result"
          raise IOError, "Oh My Pi turn did not complete" unless event["status"] == "completed"

          completed = true
          send_command.call({ "id" => "state", "type" => "get_state" }) if event["sessionSettled"]
        when "session_settled"
          send_command.call({ "id" => "state", "type" => "get_state" }) if completed
        when "response"
          if event["id"] == "state"
            persist.call(event.fetch("data").fetch("sessionFile"))
            emit.call({ "type" => "result", "result" => text.empty? ? "Completed." : text })
            return
          end
          if event["command"] == "prompt" && event.dig("data", "agentInvoked") == false
            send_command.call({ "id" => "state", "type" => "get_state" })
          end
        else
          emit.call("[Oh My Pi] #{event['type']}")
        end
      end
      raise IOError, "Oh My Pi disconnected before completing this turn"
    end
  end
end
