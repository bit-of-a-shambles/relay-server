# typed: false
# frozen_string_literal: true

require "json"

module RelayDaemon
  # Bidirectional App Server protocol. The bridge remains in SessionRunner's
  # process group, so stopping a Relay run also stops its harness and tools.
  class CodexAdapter
    def self.command(executable:, provider:, router_base:)
      argv = [executable, "app-server", "--listen", "stdio://"]
      return argv if provider == "native"

      settings = { "model_provider" => "relay", "model_providers.relay.name" => "Relay",
                   "model_providers.relay.base_url" => "#{router_base}/v1",
                   "model_providers.relay.wire_api" => "responses",
                   "model_providers.relay.env_key" => "RELAY_UPSTREAM_KEY",
                   "model_providers.relay.requires_openai_auth" => false,
                   "model_providers.relay.stream_idle_timeout_ms" => 3_600_000,
                   "model_providers.relay.request_max_retries" => 0, "model_providers.relay.stream_max_retries" => 0 }
      argv + settings.flat_map { |key, value| ["-c", "#{key}=#{JSON.generate(value)}"] }
    end

    def run(reader:, writer:, content:, native_id:, model:, mode:, persist:, emit:, decide:)
      raise ArgumentError, "Codex does not support ask_every_time" if mode == "ask_every_time"

      write = ->(value) { writer.puts(JSON.generate(value)); writer.flush }
      send_request = ->(id, method, params) { write.call({ "id" => id, "method" => method, "params" => params }) }
      send_request.call(1, "initialize", { "clientInfo" => { "name" => "relay", "version" => "1.1.0" } })
      text = ""
      reader.each_line do |line|
        event = JSON.parse(line)
        raise IOError, "Codex request failed; check model availability and Mac sign-in" if event["error"]

        params = event.fetch("params", {})
        if event["method"] && event.key?("id")
          if %w[item/commandExecution/requestApproval item/fileChange/requestApproval].include?(event["method"])
            allowed = decide.call(params)
            write.call({ "id" => event["id"], "result" => { "decision" => allowed ? "accept" : "decline" } })
          else
            write.call({ "id" => event["id"], "error" => { "code" => -32601, "message" => "This interaction is not supported by Relay" } })
          end
        elsif event["id"] == 1
          write.call({ "method" => "initialized", "params" => {} })
          setup = { "cwd" => Dir.pwd, "sandbox" => "workspace-write", "approvalPolicy" => mode == "full_auto" ? "never" : "untrusted" }
          setup["model"] = model unless model.empty?
          if native_id
            setup["threadId"] = native_id
            send_request.call(2, "thread/resume", setup)
          else
            send_request.call(2, "thread/start", setup)
          end
        elsif event["id"] == 2
          native_id = event.fetch("result").fetch("thread").fetch("id")
          persist.call(native_id)
          send_request.call(3, "turn/start", { "threadId" => native_id, "input" => [{ "type" => "text", "text" => content }] })
        elsif event["method"] == "item/agentMessage/delta"
          delta = params.fetch("delta")
          text += delta
          emit.call({ "type" => "stream_event", "event" => { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => delta } } })
        elsif event["method"] == "turn/completed"
          raise IOError, "Codex turn did not complete successfully" unless params.fetch("turn").fetch("status") == "completed"

          emit.call({ "type" => "result", "result" => text.empty? ? "Completed." : text })
          return
        elsif event["method"]
          emit.call("[Codex] #{event['method']}")
        end
      end
      raise IOError, "Codex disconnected before completing this turn"
    end
  end
end
