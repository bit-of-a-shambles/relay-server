# typed: false
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module RelayDaemon
  # Production HTTP adapter for PermissionHook, kept separate so specs can
  # inject a fake instead of making a real network call. Deliberately plain
  # Ruby (no Sorbet): this file is invoked directly by the `claude` CLI via a
  # bare `ruby permission_hook.rb`, outside any Bundler context, so it cannot
  # depend on gems.
  class NetPermissionHookHttp
    def post(uri, body, headers, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = timeout
      http.read_timeout = timeout
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      headers.each { |name, value| request[name] = value }
      request.body = body
      response = http.start { |client| client.request(request) }
      response.body
    end
  end

  # Claude Code PreToolUse hook entry point (M87). The `claude` CLI invokes
  # this as a subprocess for each matching tool call, with the hook payload
  # on stdin, and expects the PreToolUse decision JSON on stdout. Forwards
  # the tool call to the daemon's own /internal/permission-requests endpoint
  # (the same daemon that spawned this run) and relays back whatever
  # allow/deny decision it returns.
  module PermissionHook
    TIMEOUT_SECONDS = 65

    def self.decide(raw_stdin:, env:, http: NetPermissionHookHttp.new)
      payload = begin
        JSON.parse(raw_stdin)
      rescue JSON::ParserError, TypeError
        {}
      end
      payload = {} unless payload.is_a?(Hash)

      tool_name = payload["tool_name"] || payload["toolName"]
      tool_input = payload["tool_input"] || payload["toolArgs"] || {}

      sink_url = env["RELAY_PERMISSION_SINK_URL"]
      sink_token = env["RELAY_PERMISSION_SINK_TOKEN"]
      session_id = env["RELAY_SESSION_ID"]

      if sink_url.nil? || sink_token.nil? || session_id.nil? || tool_name.nil?
        return deny("Relay permission hook is not fully configured")
      end

      begin
        uri = URI.parse(sink_url)
        body = JSON.generate(
          "sessionId" => session_id,
          "runId" => env["RELAY_AGENT_RUN_ID"],
          "toolName" => tool_name,
          "toolInput" => tool_input
        )
        response_body = http.post(uri, body, { "Authorization" => "Bearer #{sink_token}" }, TIMEOUT_SECONDS)
        decision = JSON.parse(response_body)
        decision["decision"] == "allow" ? allow : deny(decision["reason"] || "denied by Relay")
      rescue StandardError => e
        deny("Relay could not reach the daemon for a permission decision: #{e.class}")
      end
    end

    def self.allow
      { "hookSpecificOutput" => { "hookEventName" => "PreToolUse", "permissionDecision" => "allow" } }
    end

    def self.deny(reason)
      {
        "hookSpecificOutput" => {
          "hookEventName" => "PreToolUse",
          "permissionDecision" => "deny",
          "permissionDecisionReason" => reason
        }
      }
    end
  end
end
