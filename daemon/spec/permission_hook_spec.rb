# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/permission_hook"

class FakePermissionHookHttp
  attr_reader :requests

  def initialize(response_body)
    @response_body = response_body
    @requests = []
  end

  def post(uri, body, headers, timeout)
    @requests << { uri: uri, body: body, headers: headers, timeout: timeout }
    @response_body
  end
end

class RaisingPermissionHookHttp
  def post(*)
    raise Errno::ECONNREFUSED, "connection refused"
  end
end

class FakeNetHttpForPermissionHook
  attr_reader :open_timeouts, :read_timeouts, :requests

  def initialize(response_body)
    @response_body = response_body
    @open_timeouts = []
    @read_timeouts = []
    @requests = []
  end

  def open_timeout=(value)
    @open_timeouts << value
  end

  def read_timeout=(value)
    @read_timeouts << value
  end

  def start
    yield self
  end

  def request(request)
    @requests << request
    Struct.new(:body).new(@response_body)
  end
end

RSpec.describe RelayDaemon::PermissionHook do
  let(:env) do
    {
      "RELAY_PERMISSION_SINK_URL" => "http://127.0.0.1:7777/internal/permission-requests",
      "RELAY_PERMISSION_SINK_TOKEN" => "internal-token",
      "RELAY_SESSION_ID" => "session-1",
      "RELAY_AGENT_RUN_ID" => "run-1"
    }
  end
  let(:stdin) { JSON.generate("tool_name" => "Bash", "tool_input" => { "command" => "rm -rf /" }) }

  it "allows when the daemon returns an allow decision, posting the tool call to the sink" do
    http = FakePermissionHookHttp.new(JSON.generate("decision" => "allow"))
    result = described_class.decide(raw_stdin: stdin, env: env, http: http)

    expect(result).to eq(
      "hookSpecificOutput" => { "hookEventName" => "PreToolUse", "permissionDecision" => "allow" }
    )
    request = http.requests.first
    expect(request[:uri].to_s).to eq(env["RELAY_PERMISSION_SINK_URL"])
    expect(request[:headers]).to eq({ "Authorization" => "Bearer internal-token" })
    expect(request[:timeout]).to eq(described_class::TIMEOUT_SECONDS)
    expect(JSON.parse(request[:body])).to eq(
      "sessionId" => "session-1", "runId" => "run-1", "toolName" => "Bash", "toolInput" => { "command" => "rm -rf /" }
    )
  end

  it "denies with the daemon's reason when the daemon denies" do
    http = FakePermissionHookHttp.new(JSON.generate("decision" => "deny", "reason" => "too risky"))
    result = described_class.decide(raw_stdin: stdin, env: env, http: http)

    expect(result.dig("hookSpecificOutput", "permissionDecision")).to eq("deny")
    expect(result.dig("hookSpecificOutput", "permissionDecisionReason")).to eq("too risky")
  end

  it "denies with a generic reason when the daemon denies without one" do
    http = FakePermissionHookHttp.new(JSON.generate("decision" => "deny"))
    result = described_class.decide(raw_stdin: stdin, env: env, http: http)

    expect(result.dig("hookSpecificOutput", "permissionDecisionReason")).to eq("denied by Relay")
  end

  it "fails closed when the daemon call raises" do
    result = described_class.decide(raw_stdin: stdin, env: env, http: RaisingPermissionHookHttp.new)

    expect(result.dig("hookSpecificOutput", "permissionDecision")).to eq("deny")
    expect(result.dig("hookSpecificOutput", "permissionDecisionReason")).to match(/could not reach the daemon/)
  end

  it "fails closed when required env vars are missing" do
    result = described_class.decide(raw_stdin: stdin, env: {}, http: FakePermissionHookHttp.new(""))

    expect(result.dig("hookSpecificOutput", "permissionDecision")).to eq("deny")
    expect(result.dig("hookSpecificOutput", "permissionDecisionReason")).to match(/not fully configured/)
  end

  it "fails closed when stdin is malformed JSON" do
    result = described_class.decide(raw_stdin: "not json", env: env, http: FakePermissionHookHttp.new(""))

    expect(result.dig("hookSpecificOutput", "permissionDecision")).to eq("deny")
  end

  it "fails closed when stdin is valid JSON but not an object" do
    result = described_class.decide(raw_stdin: "[1,2,3]", env: env, http: FakePermissionHookHttp.new(""))

    expect(result.dig("hookSpecificOutput", "permissionDecision")).to eq("deny")
  end

  it "supports the camelCase toolName/toolArgs fallback naming" do
    stdin_camel = JSON.generate("toolName" => "Bash", "toolArgs" => { "command" => "ls" })
    http = FakePermissionHookHttp.new(JSON.generate("decision" => "allow"))

    described_class.decide(raw_stdin: stdin_camel, env: env, http: http)

    expect(JSON.parse(http.requests.first[:body])).to include("toolName" => "Bash", "toolInput" => { "command" => "ls" })
  end

  it "posts through real Net::HTTP objects with the given headers and timeout" do
    fake_http = FakeNetHttpForPermissionHook.new(JSON.generate("decision" => "allow"))
    allow(Net::HTTP).to receive(:new).and_return(fake_http)

    adapter = RelayDaemon::NetPermissionHookHttp.new
    body = adapter.post(URI.parse("http://127.0.0.1:7777/internal/permission-requests"), "{}", { "Authorization" => "Bearer x" }, 65)

    expect(body).to eq(JSON.generate("decision" => "allow"))
    expect(fake_http.open_timeouts).to eq([65])
    expect(fake_http.read_timeouts).to eq([65])
    expect(fake_http.requests.first["Content-Type"]).to eq("application/json")
    expect(fake_http.requests.first["Authorization"]).to eq("Bearer x")
    expect(fake_http.requests.first.body).to eq("{}")
  end
end
