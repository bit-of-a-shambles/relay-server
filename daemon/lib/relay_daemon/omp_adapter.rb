# typed: false
# frozen_string_literal: true
require "json"
require "fileutils"

module RelayDaemon
  class OmpAdapter
    class BudgetError < IOError; end

    def initialize(provider: "native")
      @provider = provider
    end

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
      state_requested = false
      request_state = lambda do
        unless state_requested
          send_command.call({ "id" => "state", "type" => "get_state" })
          state_requested = true
        end
      end
      text = ""
      completed = false
      upstream_error = nil
      reader.each_line do |line|
        event = JSON.parse(line)
        if event["success"] == false || event["type"] == "rpc_frame_error"
          raise failure_error(event, previous: upstream_error)
        end

        case event["type"]
        when "ready"
          send_command.call({ "id" => "turn", "type" => "prompt", "message" => content })
        when "message_update"
          delta = event["assistantMessageEvent"]
          next unless delta && delta["type"] == "text_delta"

          text += delta.fetch("delta")
          emit.call({ "type" => "stream_event", "event" => { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => delta.fetch("delta") } } })
        when "message_end"
          message = event.fetch("message", {})
          if message["role"] == "assistant"
            upstream_error = message["stopReason"] == "error" ? message : nil
            if upstream_error
              error = failure_error({}, previous: upstream_error)
              raise error if error.is_a?(BudgetError)
            end
          end
          emit.call("[Oh My Pi] message_end")
        when "agent_end"
          if event["isTerminal"] != false
            raise failure_error({}, previous: upstream_error) if upstream_error

            # OMP 17.3.5 completes model turns here and emits no prompt_result.
            # Newer yielded events use the prompt_result/session_settled path.
            request_state.call unless event.key?("yielded")
          end

          emit.call("[Oh My Pi] agent_end")
        when "prompt_result"
          local_completion = event["agentInvoked"] == false && !event.key?("status")
          if upstream_error || (!local_completion && event["status"] != "completed")
            raise failure_error(event, previous: upstream_error, fallback: "Oh My Pi turn did not complete")
          end

          completed = true
          request_state.call if local_completion || event["sessionSettled"]
        when "session_settled"
          request_state.call if completed
        when "response"
          if event["id"] == "state"
            persist.call(event.fetch("data").fetch("sessionFile"))
            emit.call({ "type" => "result", "result" => text.empty? ? "Completed." : text })
            return
          end
          if event["command"] == "prompt" && event.dig("data", "agentInvoked") == false
            request_state.call
          end
        else
          emit.call("[Oh My Pi] #{event['type']}")
        end
      end
      raise failure_error({}, previous: upstream_error) if upstream_error

      raise IOError, "Oh My Pi disconnected before completing this turn"
    end

    private

    def failure_error(event, previous: nil, fallback: "Oh My Pi request failed")
      detail = previous || event["error"] || event["errorMessage"] || event["message"] || {}
      status = detail["errorStatus"] if detail.is_a?(Hash)
      detail = detail["errorMessage"] || detail if detail.is_a?(Hash)
      raw = detail.is_a?(String) ? detail : ""
      status ||= raw[/\A(\d{3})\b/, 1]
      if detail.is_a?(String)
        begin
          detail = JSON.parse(detail.sub(/\A\d{3}\s+/, ""))
        rescue JSON::ParserError
          detail = { "message" => detail }
        end
      end
      detail = {} unless detail.is_a?(Hash)
      detail = detail["error"] if detail["error"].is_a?(Hash)
      status ||= detail["code"]
      metadata = detail["metadata"].is_a?(Hash) ? detail["metadata"] : {}
      if status.to_s == "402" || metadata["reason"] == "in_flight_budget_exhausted"
        if @provider == "openrouter" || metadata["reason"] == "in_flight_budget_exhausted"
          return BudgetError.new("OpenRouter budget exhausted. [Add OpenRouter credits](https://openrouter.ai/settings/credits) to continue.")
        end

        return BudgetError.new("Model provider budget exhausted. Add credits or increase the provider budget to continue.")
      end
      status = status.to_s.match?(/\A[1-5]\d{2}\z/) ? " (HTTP #{status})" : ""
      message = detail["message"].is_a?(String) ? detail["message"] : ""
      message = message.sub(/\A\d{3}\s+/, "").sub(/\s*retry-after-ms=\d+/, "")
      message = "" if message.lstrip.start_with?("{", "[")
      message = sanitize_error(message)
      headers = metadata["headers"].is_a?(Hash) ? metadata["headers"] : {}
      retry_after = headers["Retry-After"].to_s
      retry_ms = raw[/retry-after-ms=(\d+)/, 1]
      retry_after = ((retry_ms.to_i + 999) / 1000).to_s if retry_ms
      retry_hint = retry_after.match?(/\A\d+\z/) ? " Retry after #{retry_after} seconds." : ""
      IOError.new("#{fallback}#{status}#{message.empty? ? '.' : ": #{message}"}#{retry_hint}")
    end

    def sanitize_error(message)
      ENV.each do |name, value|
        message = message.gsub(value, "[REDACTED]") if name.match?(/KEY|TOKEN|SECRET|PASSWORD/i) && value.length >= 6
      end
      message.gsub(%r{https?://\S+}, "[URL omitted]")
        .gsub(/\bBearer\s+\S+/i, "Bearer [REDACTED]")
        .gsub(/\b(?:sk-[\w-]+|gh[pousr]_[\w]+)/, "[REDACTED]")
        .gsub(/((?:api[-_ ]?key|token|secret|password)["']?\s*[:=]\s*["']?)[^\s,"';]+/i, '\1[REDACTED]')
        .gsub(/[[:cntrl:]]/, " ").strip[0, 500]
    end
  end
end
