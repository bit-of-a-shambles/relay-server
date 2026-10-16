# frozen_string_literal: true
require "spec_helper"
require "stringio"
require "relay_daemon/omp_adapter"

RSpec.describe RelayDaemon::OmpAdapter do
  def run_frames(frames)
    @events, @writer = [], StringIO.new
    described_class.new.run(reader: StringIO.new(frames.map(&:to_json).join("\n")), writer: @writer,
      content: "fix", native_id: nil, model: "coder", mode: "full_auto", persist: ->(id) { @native = id }, emit: ->(event) { @events << event }, decide: ->(_) { false })
  end
  let(:state) { { type: "response", id: "state", success: true, data: { sessionFile: "/private/omp-session.jsonl" } } }
  it "waits for settled turns, streams text and persists the resumable session file" do
    run_frames([{ type: "ready" }, { type: "response", command: "prompt", success: true }, { type: "agent_start" },
      { type: "message_update" }, { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "Done" } },
      { type: "prompt_result", status: "completed", sessionSettled: false }, { type: "session_settled" }, state])
    expect(@native).to eq("/private/omp-session.jsonl")
    expect(@events.last).to eq("type" => "result", "result" => "Done")
    expect(@writer.string).to include('"type":"prompt"', '"type":"get_state"')
    expect(@events).to include("[Oh My Pi] agent_start")
    run_frames([{ type: "prompt_result", status: "completed", sessionSettled: true }, state])
    expect(@events.last["result"]).to eq("Completed.")
    run_frames([{ type: "response", command: "prompt", data: { agentInvoked: false } }, state])
    expect(@writer.string).to include('"type":"get_state"')
  end
  it "reports command, frame, turn and EOF failures" do
    expect { run_frames([{ type: "response", success: false }]) }.to raise_error(IOError, /sign-in/)
    expect { run_frames([{ type: "rpc_frame_error" }]) }.to raise_error(IOError)
    expect { run_frames([{ type: "prompt_result", status: "error" }]) }.to raise_error(IOError, /complete/)
    expect { run_frames([]) }.to raise_error(IOError, /disconnected/)
  end
  it "isolates routed models from global configuration and requires explicit full-auto" do
    directory = Dir.mktmpdir
    args = { executable: "omp", provider: "native", router_base: "http://router", model: "", native_id: nil, mode: "full_auto", session_dir: directory }
    expect(described_class.command(**args)).not_to include("--resume", "--model")
    expect(described_class.command(**args.merge(provider: "ollama", model: "ollama::coder", native_id: "session.jsonl"))).to include("relay/ollama::coder", "--resume", "session.jsonl")
    expect { described_class.command(**args.merge(mode: "ask_on_sensitive")) }.to raise_error(ArgumentError)
    expect(described_class.environment(provider: "native", router_base: "http://router", model: "", session_dir: directory)).to eq({})
    env = described_class.environment(provider: "ollama", router_base: "http://router", model: "ollama::coder", session_dir: directory)
    path = File.join(env["PI_CODING_AGENT_DIR"], "models.yml")
    expect(JSON.parse(File.read(path)).dig("providers", "relay", "baseUrl")).to eq("http://router/v1")
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end
end
