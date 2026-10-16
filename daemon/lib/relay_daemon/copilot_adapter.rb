# typed: false
# frozen_string_literal: true
require "json"

module RelayDaemon
  class CopilotAdapter
    def self.command(executable:, provider:, router_base:, model:)
      command = [executable, "--acp", "--stdio"]
      model.empty? ? command : command + ["--model", model]
    end

    def self.environment(provider:, router_base:, model:)
      return {} if provider == "native"

      { "COPILOT_PROVIDER_TYPE" => "openai", "COPILOT_PROVIDER_BASE_URL" => "#{router_base}/v1",
        "COPILOT_PROVIDER_API_KEY" => "relay-dummy", "COPILOT_PROVIDER_WIRE_API" => "chat",
        "COPILOT_PROVIDER_WIRE_MODEL" => model, "COPILOT_MODEL" => model, "COPILOT_OFFLINE" => "true" }
    end

    def run(reader:, writer:, content:, native_id:, model:, mode:, persist:, emit:, decide:)
      send_request = lambda do |id, method, params|
        writer.puts(JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }))
        writer.flush
      end
      send_request.call(1, "initialize", { "protocolVersion" => 1, "clientCapabilities" => {} })
      text = ""
      reader.each_line do |line|
        event = JSON.parse(line)
        raise IOError, "Copilot request failed; check model availability and Mac sign-in" if event["error"]

        params = event.fetch("params", {})
        if event["method"] == "session/request_permission"
          kind = decide.call(params) ? "allow_once" : "reject_once"
          option = params.fetch("options").find { |item| item["kind"] == kind }
          outcome = option ? { "outcome" => "selected", "optionId" => option.fetch("optionId") } : { "outcome" => "cancelled" }
          writer.puts(JSON.generate({ "jsonrpc" => "2.0", "id" => event.fetch("id"), "result" => { "outcome" => outcome } }))
          writer.flush
        elsif event["method"] && event.key?("id")
          writer.puts(JSON.generate({ "jsonrpc" => "2.0", "id" => event["id"], "error" => { "code" => -32601, "message" => "Unsupported client operation" } }))
          writer.flush
        elsif event["id"] == 1
          setup = { "cwd" => Dir.pwd, "mcpServers" => [] }
          setup["sessionId"] = native_id if native_id
          send_request.call(2, native_id ? "session/load" : "session/new", setup)
        elsif event["id"] == 2
          native_id ||= event.fetch("result").fetch("sessionId")
          persist.call(native_id)
          send_request.call(3, "session/prompt", { "sessionId" => native_id, "prompt" => [{ "type" => "text", "text" => content }] })
        elsif event["id"] == 3
          raise IOError, "Copilot turn did not complete" unless event.dig("result", "stopReason") == "end_turn"

          emit.call({ "type" => "result", "result" => text.empty? ? "Completed." : text })
          return
        elsif event["method"] == "session/update"
          update = params.fetch("update")
          if update["sessionUpdate"] == "agent_message_chunk" && update.dig("content", "type") == "text"
            delta = update.fetch("content").fetch("text")
            text += delta
            emit.call({ "type" => "stream_event", "event" => { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => delta } } })
          else
            emit.call("[Copilot] #{update['sessionUpdate']}")
          end
        end
      end
      raise IOError, "Copilot disconnected before completing this turn"
    end
  end
end
