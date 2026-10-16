#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
STDOUT.sync = true
abort "Expected explicit headless full-auto" unless ARGV.include?("yolo")
File.open("gemini_arguments.jsonl", "a") { |file| file.puts(ARGV.to_json) }
puts({ type: "init", session_id: "gemini-fixture-session" }.to_json)
prompt = ARGV[ARGV.index("--prompt") + 1]
sleep 60 if prompt == "wait"
puts({ type: "message", role: "assistant", content: "Gemini fixture reply" }.to_json)
puts({ type: "result", status: "success" }.to_json)
