# frozen_string_literal: true
require "spec_helper"
require "stringio"
require "relay_daemon/codex_adapter"

RSpec.describe RelayDaemon::CodexAdapter do
  def run_frames(frames, native: nil, model: "vendor/coder", mode: "ask_on_sensitive", allowed: true)
    @writer, @emitted, @persisted = StringIO.new, [], []
    described_class.new.run(reader: StringIO.new(frames.map(&:to_json).join("\n") + "\n"), writer: @writer,
      content: "fix it", native_id: native, model: model, mode: mode,
      persist: ->(id) { @persisted << id }, emit: ->(event) { @emitted << event }, decide: ->(_params) { allowed })
  end
  let(:start) { [{ id: 1, result: {} }, { id: 2, result: { thread: { id: "native-thread" } } }, { id: 3, result: {} }] }
  let(:finish) { { method: "turn/completed", params: { turn: { status: "completed" } } } }

  it "starts and resumes distinct native sessions, normalizing text and approval decisions" do
    [nil, "native-thread"].each do |native|
      run_frames(start + [{ id: 99, method: "item/commandExecution/requestApproval", params: { command: "ls" } },
        { method: "item/agentMessage/delta", params: { delta: "Done" } }, { method: "item/started", params: {} }, finish], native: native)
      requests = @writer.string.lines.map { |line| JSON.parse(line) }
      expect(requests[2]["method"]).to eq(native ? "thread/resume" : "thread/start")
      expect(requests[2]["params"]["model"]).to eq("vendor/coder")
      expect(requests.last).to include("id" => 99, "result" => { "decision" => "accept" })
      expect(@persisted).to eq(["native-thread"])
      expect(@emitted.last).to eq("type" => "result", "result" => "Done")
      expect(@emitted).to include("[Codex] item/started")
    end
  end
  it "denies rejected approvals and unsupported interactions, and handles empty native-model replies" do
    run_frames(start + [{ id: 99, method: "item/fileChange/requestApproval", params: {} }, { id: 100, method: "tool/requestUserInput", params: {} }, finish], model: "", mode: "full_auto", allowed: false)
    requests = @writer.string.lines.map { |line| JSON.parse(line) }
    expect(requests[2]["params"]).to include("approvalPolicy" => "never")
    expect(requests[2]["params"]).not_to have_key("model")
    expect(requests[-2]["result"]["decision"]).to eq("decline")
    expect(requests.last["error"]["code"]).to eq(-32601)
    expect(@emitted.last["result"]).to eq("Completed.")
  end
  it "reports protocol, authentication, disconnected and failed turns" do
    expect { run_frames([{ id: 1, error: { message: "bad auth" } }]) }.to raise_error(IOError, /sign-in/)
    expect { run_frames(start + [{ method: "turn/completed", params: { turn: { status: "failed" } } }]) }.to raise_error(IOError, /successfully/)
    expect { run_frames(start) }.to raise_error(IOError, /disconnected/)
    expect { run_frames(start, mode: "ask_every_time") }.to raise_error(ArgumentError)
  end
  it "configures routed inference only for the child and leaves native auth intact" do
    native = described_class.command(executable: "/a path/codex", provider: "native", router_base: "http://localhost/api")
    expect(native).to eq(["/a path/codex", "app-server", "--listen", "stdio://"])
    routed = described_class.command(executable: "codex", provider: "doubleword", router_base: "http://localhost/api/session/s/run/r")
    expect(routed).to include('model_providers.relay.base_url="http://localhost/api/session/s/run/r/v1"')
    expect(routed).to include('model_providers.relay.wire_api="responses"')
  end
end
