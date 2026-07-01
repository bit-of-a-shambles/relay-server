#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

EVAL_CASE_PATH = "eval_case.json"

def fail_with_tests(message, raw_response: nil)
  details = { error: message }
  details[:rawResponse] = raw_response if raw_response
  File.write("relay_eval_agent_error.json", JSON.pretty_generate(details))
  warn message
  exit 0
end

def safe_relative_path?(path)
  return false if path.nil? || path.empty?
  return false if path.start_with?("/")

  expanded = File.expand_path(path, Dir.pwd)
  expanded.start_with?("#{Dir.pwd}/")
end

def read_eval_case
  JSON.parse(File.read(EVAL_CASE_PATH))
rescue Errno::ENOENT
  fail_with_tests("#{EVAL_CASE_PATH} is missing")
rescue JSON::ParserError => e
  fail_with_tests("#{EVAL_CASE_PATH} is invalid JSON: #{e.message}")
end

def read_context(eval_case)
  editable = eval_case.fetch("editableFiles")
  files = (editable + Dir.glob("test_*.rb")).uniq.sort
  files.to_h do |path|
    fail_with_tests("unsafe context path: #{path}") unless safe_relative_path?(path)
    [path, File.read(path)]
  end
end

def prompt_for(eval_case, files)
  file_blocks = files.map do |path, content|
    <<~TEXT
      --- #{path}
      ```ruby
      #{content}
      ```
    TEXT
  end.join("\n")

  <<~PROMPT
    You are editing a tiny Ruby repository for a deterministic coding eval.
    Return JSON only. Do not wrap it in Markdown.

    Required JSON shape:
    {"files":{"relative/path.rb":"complete replacement file content"}}

    Rules:
    - Edit only these files: #{eval_case.fetch("editableFiles").join(", ")}
    - Do not edit tests or eval_case.json.
    - Return complete replacement contents for each edited file.
    - Keep the answer compact and ASCII.

    Request:
    #{eval_case.fetch("prompt")}

    Test command:
    #{eval_case.fetch("testCommand")}

    Current files:
    #{file_blocks}
  PROMPT
end

def call_model(prompt)
  base_url = ENV.fetch("ANTHROPIC_BASE_URL") do
    fail_with_tests("ANTHROPIC_BASE_URL is required")
  end
  max_tokens = ENV.fetch("RELAY_EVAL_MAX_TOKENS", "900").to_i
  fail_with_tests("RELAY_EVAL_MAX_TOKENS must be positive") unless max_tokens.positive?

  uri = URI("#{base_url}/v1/messages")
  request = Net::HTTP::Post.new(uri)
  request["content-type"] = "application/json"
  request["x-api-key"] = ENV.fetch("ANTHROPIC_API_KEY", "relay-eval")
  request["anthropic-version"] = "2023-06-01"
  request.body = JSON.generate(
    model: "claude-3-5-haiku-20241022",
    max_tokens: max_tokens,
    metadata: { qualityDial: 0 },
    messages: [
      {
        role: "user",
        content: prompt
      }
    ]
  )

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(request)
  end

  unless response.is_a?(Net::HTTPSuccess)
    warn "model call failed: HTTP #{response.code}"
    warn response.body.to_s[0, 500]
    exit 1
  end

  payload = JSON.parse(response.body)
  payload.fetch("content", []).filter_map do |part|
    part["text"] if part.is_a?(Hash) && part["type"] == "text"
  end.join
rescue JSON::ParserError => e
  fail_with_tests("model response was not valid router JSON: #{e.message}")
end

def extract_json(text)
  stripped = text.strip
  fenced = stripped.match(/```(?:json)?\s*(.*?)\s*```/m)
  return fenced[1] if fenced

  first = stripped.index("{")
  last = stripped.rindex("}")
  return nil unless first && last && last >= first

  stripped[first..last]
end

def normalize_files(value)
  case value
  when Hash
    value
  when Array
    value.to_h do |entry|
      unless entry.is_a?(Hash) && entry.key?("path") && entry.key?("content")
        fail_with_tests("files array entries must have path and content")
      end
      [entry.fetch("path"), entry.fetch("content")]
    end
  else
    fail_with_tests("model JSON must contain a files object")
  end
end

def parse_model_edit(text)
  json_text = extract_json(text)
  fail_with_tests("model did not return JSON", raw_response: text) unless json_text

  payload = JSON.parse(json_text)
  files = payload["files"]
  fail_with_tests("model JSON omitted files", raw_response: text) if files.nil?

  normalize_files(files)
rescue JSON::ParserError => e
  fail_with_tests("model edit JSON could not be parsed: #{e.message}", raw_response: text)
end

def apply_edits(files, editable_files)
  editable = editable_files.to_h { |path| [path, true] }
  applied = []

  files.each do |path, content|
    fail_with_tests("model tried to edit unsafe path: #{path}") unless safe_relative_path?(path)
    fail_with_tests("model tried to edit non-editable path: #{path}") unless editable[path]
    fail_with_tests("model content for #{path} is not a string") unless content.is_a?(String)

    File.write(path, content)
    applied << path
  end

  fail_with_tests("model returned no editable files") if applied.empty?
  applied
end

eval_case = read_eval_case
files = read_context(eval_case)
response_text = call_model(prompt_for(eval_case, files))
edits = parse_model_edit(response_text)
applied = apply_edits(edits, eval_case.fetch("editableFiles"))

puts "applied model edits: #{applied.join(", ")}"
