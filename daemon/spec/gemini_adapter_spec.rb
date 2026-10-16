# frozen_string_literal: true
require "spec_helper"
require "stringio"
require "relay_daemon/gemini_adapter"

RSpec.describe RelayDaemon::GeminiAdapter do
  def run_frames(frames)
    @events, @native = [], nil
    described_class.new.run(reader: StringIO.new(frames.map(&:to_json).join("\n") + "\n"), writer: StringIO.new,
      content: "fix", native_id: nil, model: "", mode: "full_auto", persist: ->(id) { @native = id }, emit: ->(event) { @events << event }, decide: ->(_) { false })
  end
  it "normalizes session IDs, streamed assistant text, tool activity and completion" do
    run_frames([{ type: "init", session_id: "gemini-session" }, { type: "message", role: "user", content: "prompt" },
      { type: "message", role: "assistant", content: "Done" }, { type: "tool_use" }, { type: "result", status: "success" }])
    expect(@native).to eq("gemini-session")
    expect(@events.last).to eq("type" => "result", "result" => "Done")
    expect(@events).to include("[Gemini] tool_use")
    run_frames([{ type: "result", status: "success" }])
    expect(@events.last["result"]).to eq("Completed.")
  end
  it "reports authentication, unsuccessful completion and premature EOF" do
    expect { run_frames([{ type: "error" }]) }.to raise_error(IOError, /sign-in/)
    expect { run_frames([{ type: "result", status: "error" }]) }.to raise_error(IOError, /failed/)
    expect { run_frames([]) }.to raise_error(IOError, /disconnected/)
  end
  it "requires native authentication and explicit full-auto, preserving model and resume arguments" do
    args = { executable: "gemini", provider: "native", router_base: "ignored", model: "", content: "prompt", native_id: nil, mode: "full_auto" }
    expect(described_class.command(**args)).not_to include("--resume", "--model")
    expect(described_class.command(**args.merge(model: "gemini-test", native_id: "thread"))).to include("--model", "gemini-test", "--resume", "thread")
    expect { described_class.command(**args.merge(provider: "openrouter")) }.to raise_error(ArgumentError)
    expect { described_class.command(**args.merge(mode: "ask_on_sensitive")) }.to raise_error(ArgumentError)
  end
end
