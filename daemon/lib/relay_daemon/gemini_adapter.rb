# typed: false
# frozen_string_literal: true
require "json"

module RelayDaemon
  class GeminiAdapter
    def self.command(executable:, provider:, router_base:, model:, content:, native_id:, mode:)
      raise ArgumentError, "Gemini supports native Google models only" unless provider == "native"
      raise ArgumentError, "Gemini headless requires explicitly selected full_auto mode" unless mode == "full_auto"

      command = [executable, "--prompt", content, "--output-format", "stream-json", "--approval-mode", "yolo"]
      command += ["--model", model] unless model.empty?
      command += ["--resume", native_id] if native_id
      command
    end

    def run(reader:, writer:, content:, native_id:, model:, mode:, persist:, emit:, decide:)
      text = ""
      reader.each_line do |line|
        next if line.strip.empty?

        event = JSON.parse(line)
        case event["type"]
        when "init"
          persist.call(event.fetch("session_id"))
        when "message"
          next unless event["role"] == "assistant"

          delta = event.fetch("content")
          text += delta
          emit.call({ "type" => "stream_event", "event" => { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => delta } } })
        when "error"
          raise IOError, "Gemini CLI error; check Mac sign-in, model access and quota"
        when "result"
          raise IOError, "Gemini turn failed" unless event["status"] == "success"

          emit.call({ "type" => "result", "result" => text.empty? ? "Completed." : text })
          return
        else
          emit.call("[Gemini] #{event['type']}")
        end
      end
      raise IOError, "Gemini disconnected before completing this turn"
    end
  end
end
