#!/usr/bin/env ruby
# frozen_string_literal: true

prompt = ARGV[0].to_s
mode_index = ARGV.index("--resume") || ARGV.index("--session-id")
mode = mode_index ? ARGV[mode_index].delete_prefix("--") : "none"
token = mode_index ? ARGV[mode_index + 1].to_s : ""

sleep 0.2 if prompt.include?("slow")

File.open("session_agent_runs.txt", "a") do |file|
  file.puts("#{mode}:#{token}:#{prompt}")
end

puts "mode=#{mode}"
puts "token=#{token}"
puts "prompt=#{prompt}"
