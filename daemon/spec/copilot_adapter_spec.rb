# frozen_string_literal: true
require "spec_helper"
require "stringio"
require "relay_daemon/copilot_adapter"

RSpec.describe RelayDaemon::CopilotAdapter do
  let(:start) { [{ id: 1, result: {} }, { id: 2, result: { sessionId: "copilot-native" } }] }
  let(:finish) { { id: 3, result: { stopReason: "end_turn" } } }
  def run_frames(frames, native: nil, allowed: true)
    @writer, @events = StringIO.new, []
    described_class.new.run(reader: StringIO.new(frames.map(&:to_json).join("\n") + "\n"), writer: @writer, content: "fix", native_id: native, model: "coder", mode: "ask_on_sensitive",
      persist: ->(id) { @native = id }, emit: ->(event) { @events << event }, decide: ->(_params) { allowed })
  end
  it "starts and loads sessions with incremental messages and live once-only permissions" do
    [nil, "copilot-native"].each do |native|
      run_frames(start + [{ id: 9, method: "session/request_permission", params: { options: [{ kind: "allow_once", optionId: "yes" }] } },
        { method: "session/update", params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done" } } } },
        { method: "session/update", params: { update: { sessionUpdate: "tool_call" } } }, finish], native: native)
      writes = @writer.string.lines.map { |line| JSON.parse(line) }
      expect(writes[1]["method"]).to eq(native ? "session/load" : "session/new")
      expect(writes.last.dig("result", "outcome", "optionId")).to eq("yes")
      expect(@native).to eq("copilot-native")
      expect(@events.last).to eq("type" => "result", "result" => "Done")
      expect(@events).to include("[Copilot] tool_call")
    end
  end
  it "rejects or cancels permissions and refuses unsupported client filesystem operations" do
    [[], [{ kind: "reject_once", optionId: "no" }]].each do |options|
      run_frames(start + [{ id: 9, method: "session/request_permission", params: { options: options } }, { id: 10, method: "fs/write_text_file", params: {} }, finish], allowed: false)
      writes = @writer.string.lines.map { |line| JSON.parse(line) }
      expect(writes[-2].dig("result", "outcome", "outcome")).to eq(options.empty? ? "cancelled" : "selected")
      expect(writes.last["error"]["code"]).to eq(-32601)
      expect(@events.last["result"]).to eq("Completed.")
    end
  end
  it "reports failed requests, incomplete turns and disconnections" do
    expect { run_frames([{ id: 1, error: {} }]) }.to raise_error(IOError, /sign-in/)
    expect { run_frames(start + [{ id: 3, result: { stopReason: "cancelled" } }]) }.to raise_error(IOError, /complete/)
    expect { run_frames(start) }.to raise_error(IOError, /disconnected/)
  end
  it "keeps native auth and confines BYOK routing to the child environment" do
    expect(described_class.command(executable: "copilot", provider: "native", router_base: "http://router", model: "")).to eq(%w[copilot --acp --stdio])
    expect(described_class.command(executable: "copilot", provider: "ollama", router_base: "http://router", model: "ollama::coder")).to include("--model", "ollama::coder")
    expect(described_class.environment(provider: "native", router_base: "http://router", model: "")).to eq({})
    expect(described_class.environment(provider: "ollama", router_base: "http://router", model: "ollama::coder")).to include("COPILOT_PROVIDER_BASE_URL" => "http://router/v1", "COPILOT_MODEL" => "ollama::coder", "COPILOT_OFFLINE" => "true")
  end
end
