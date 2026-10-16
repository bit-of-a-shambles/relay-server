#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
STDOUT.sync = true
File.write("copilot_environment.json", JSON.generate(ENV.to_h.select { |key, _| key.start_with?("COPILOT_") }))
STDIN.each_line do |line|
  data = JSON.parse(line)
  File.open("copilot_requests.jsonl", "a") { |file| file.puts(line) }
  result = case data["method"]
           when "initialize" then { protocolVersion: 1 }
           when "session/new", "session/load" then { sessionId: data.dig("params", "sessionId") || "copilot-fixture-session" }
           when "session/prompt"
             sleep 60 if data.dig("params", "prompt", 0, "text") == "wait"
             puts({ method: "session/update", params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Copilot fixture reply" } } } }.to_json)
             { stopReason: "end_turn" }
           end
  puts({ id: data["id"], result: result }.to_json)
end
