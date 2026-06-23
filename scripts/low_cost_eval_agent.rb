#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

base_url = ENV.fetch("ANTHROPIC_BASE_URL") do
  warn "ANTHROPIC_BASE_URL is required"
  exit 1
end

uri = URI("#{base_url}/v1/messages")
request = Net::HTTP::Post.new(uri)
request["content-type"] = "application/json"
request["x-api-key"] = ENV.fetch("ANTHROPIC_API_KEY", "relay-eval")
request["anthropic-version"] = "2023-06-01"
request.body = JSON.generate(
  model: "claude-3-5-haiku-20241022",
  max_tokens: 8,
  metadata: { qualityDial: 0 },
  messages: [
    {
      role: "user",
      content: "Reply with exactly RELAY_EVAL_OK and no other text."
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
text = payload.fetch("content", []).filter_map do |part|
  part["text"] if part.is_a?(Hash) && part["type"] == "text"
end.join

File.write("answer.txt", text)
puts "wrote answer.txt from routed model response"
