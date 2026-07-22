# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/runtime_environment"
require "tmpdir"

RSpec.describe RelayDaemon::RuntimeEnvironment do
  it "adds private routing-loop defaults without replacing operator overrides" do
    home = Dir.mktmpdir
    env = described_class.prepare(
      {
        "RELAY_DAEMON_PORT" => "17777",
        "RELAY_ROUTING_CONFIG" => "/custom/routing.json"
      },
      home: home,
      token_generator: -> { "generated-token" }
    )

    expect(env).to include(
      "RELAY_INTERNAL_TOKEN" => "generated-token",
      "RELAY_ROUTING_CONFIG" => "/custom/routing.json",
      "RELAY_LLM_CALL_SINK_URL" => "http://127.0.0.1:17777/internal/llm-calls",
      "RELAY_LLM_CALL_SINK_TOKEN" => "generated-token"
    )
  end

  it "uses the standard Relay routing path and preserves complete sink overrides" do
    home = Dir.mktmpdir
    env = described_class.prepare(
      {
        "RELAY_INTERNAL_TOKEN" => "operator-token",
        "RELAY_LLM_CALL_SINK_URL" => "https://sink.example.test/calls",
        "RELAY_LLM_CALL_SINK_TOKEN" => "sink-token"
      },
      home: home,
      token_generator: -> { raise "must not generate" }
    )

    expect(env["RELAY_ROUTING_CONFIG"]).to eq(File.join(home, ".relay", "routing.json"))
    expect(env["RELAY_LLM_CALL_SINK_URL"]).to eq("https://sink.example.test/calls")
    expect(env["RELAY_LLM_CALL_SINK_TOKEN"]).to eq("sink-token")
  end

  it "rejects a partial call-sink override" do
    expect do
      described_class.prepare(
        { "RELAY_LLM_CALL_SINK_URL" => "https://sink.example.test/calls" },
        home: Dir.mktmpdir,
        token_generator: -> { "generated-token" }
      )
    end.to raise_error(ArgumentError, /must be set together/)
  end
end
