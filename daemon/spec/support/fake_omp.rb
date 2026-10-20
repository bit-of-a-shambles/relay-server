#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
STDOUT.sync = true
File.open("omp_arguments.jsonl", "a") { |file| file.puts(ARGV.to_json) }
puts({ type: "ready" }.to_json)
STDIN.each_line do |line|
  data = JSON.parse(line)
  if data["type"] == "prompt"
    sleep 60 if data["message"] == "wait"
    if data["message"] == "credit limit"
      error = { error: { message: "Available credits are reserved by in-flight requests.", code: 402,
        metadata: { headers: { "Retry-After" => "120" } } }, user_id: "private-account" }
      puts({ type: "message_end", message: { role: "assistant", stopReason: "error", errorStatus: 402, errorMessage: "402 #{error.to_json}" } }.to_json)
      sleep 60 # OMP must be stopped before it waits for or attempts a budget retry.
      puts({ type: "agent_end", isTerminal: true }.to_json)
      next
    end
    puts({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "OMP fixture reply" } }.to_json)
    if ["terminal", "legacy"].include?(data["message"])
      puts({ type: "agent_end", isTerminal: false }.to_json)
      completion = { type: "agent_end" }
      completion[:isTerminal] = true if data["message"] == "terminal"
      puts(completion.to_json)
    else
      puts({ type: "prompt_result", status: "completed", sessionSettled: true }.to_json)
    end
  elsif data["type"] == "get_state"
    puts({ type: "response", id: data["id"], success: true, data: { sessionFile: "/fixture/omp-native.jsonl" } }.to_json)
  end
end
