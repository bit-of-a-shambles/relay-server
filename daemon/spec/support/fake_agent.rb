#!/usr/bin/env ruby
# frozen_string_literal: true
# Fake agent for tests. Writes prompt to agent_ran.txt in cwd and the
# RELAY_TASK_ID env var to env_task_id.txt.
# Exit code = ARGV[1].to_i (default 0). ARGV[0] is the prompt.
puts "agent line one"
puts "agent line two"
File.write("agent_argv.txt", ARGV.join("\n"))
File.write("agent_ran.txt", ARGV[0].to_s)
File.write("env_task_id.txt", ENV["RELAY_TASK_ID"].to_s)
File.write("env_anthropic_base.txt", ENV["ANTHROPIC_BASE_URL"].to_s)
exit(ARGV[1].to_i)
