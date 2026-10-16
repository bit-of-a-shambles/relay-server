#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
STDOUT.sync = true
File.write("codex_router_base.txt", ENV["ANTHROPIC_BASE_URL"].to_s)
STDIN.each_line do |line|
  data = JSON.parse(line)
  File.open("codex_requests.jsonl", "a") { |file| file.puts(line) }
  case data["method"]
  when "initialize"
    puts({ id: data["id"], result: {} }.to_json)
  when "thread/start", "thread/resume"
    abort "Invalid sandbox enum" unless data.dig("params", "sandbox") == "workspace-write"
    puts({ id: data["id"], result: { thread: { id: data.dig("params", "threadId") || "fixture-native-thread" } } }.to_json)
  when "turn/start"
    puts({ id: data["id"], result: { turn: { id: "fixture-turn" } } }.to_json)
    sleep 60 if data.dig("params", "input", 0, "text") == "wait"
    puts({ method: "item/agentMessage/delta", params: { delta: "Codex fixture reply" } }.to_json)
    puts({ method: "turn/completed", params: { turn: { status: "completed" } } }.to_json)
  end
end
