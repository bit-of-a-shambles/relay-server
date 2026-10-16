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
    puts({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "OMP fixture reply" } }.to_json)
    puts({ type: "prompt_result", status: "completed", sessionSettled: true }.to_json)
  elsif data["type"] == "get_state"
    puts({ type: "response", id: data["id"], success: true, data: { sessionFile: "/fixture/omp-native.jsonl" } }.to_json)
  end
end
