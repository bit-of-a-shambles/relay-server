# frozen_string_literal: true
require "spec_helper"
require "stringio"
require "relay_daemon/omp_adapter"

RSpec.describe RelayDaemon::OmpAdapter do
  def run_frames(frames, provider: "openrouter")
    @events, @writer = [], StringIO.new
    described_class.new(provider: provider).run(reader: StringIO.new(frames.map(&:to_json).join("\n")), writer: @writer,
      content: "fix", native_id: nil, model: "coder", mode: "full_auto", persist: ->(id) { @native = id }, emit: ->(event) { @events << event }, decide: ->(_) { false })
  end
  let(:state) { { type: "response", id: "state", success: true, data: { sessionFile: "/private/omp-session.jsonl" } } }
  let(:funding_prompt) { "OpenRouter budget exhausted. [Add OpenRouter credits](https://openrouter.ai/settings/credits) to continue." }
  let(:credit_error) do
    { error: { message: "This request would exceed your available credits given your current in-flight requests.", code: 402,
      metadata: { reason: "in_flight_budget_exhausted", headers: { "Retry-After" => "120" }, private_key: "private-metadata" } },
      user_id: "private-account" }
  end
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
    expect { run_frames([{ type: "response", success: false }]) }.to raise_error(IOError, "Oh My Pi request failed.")
    expect { run_frames([{ type: "rpc_frame_error" }]) }.to raise_error(IOError)
    expect { run_frames([{ type: "prompt_result", status: "error" }]) }.to raise_error(IOError, /complete/)
    expect { run_frames([]) }.to raise_error(IOError, /disconnected/)
  end

  it "completes installed and legacy terminal events without a prompt_result" do
    [{ type: "agent_end", isTerminal: true }, { type: "agent_end" }].each do |completion|
      run_frames([{ type: "ready" },
        { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "Finished" } },
        { type: "message_end", message: { role: "assistant", stopReason: "stop" } }, completion, state])
      expect(@native).to eq("/private/omp-session.jsonl")
      expect(@events.last).to eq("type" => "result", "result" => "Finished")
      expect(@writer.string.lines.map { |line| JSON.parse(line)["type"] }).to eq(%w[prompt get_state])
    end
  end

  it "does not treat maintenance or newer yielded events as settled completion" do
    [{ type: "agent_end", isTerminal: false }, { type: "agent_end", isTerminal: true, yielded: true },
      { type: "session_settled" }].each do |event|
      expect { run_frames([event]) }.to raise_error(IOError, /disconnected/)
      expect(@writer.string).to be_empty
    end
    run_frames([{ type: "agent_end", isTerminal: true, yielded: true },
      { type: "prompt_result", status: "completed", sessionSettled: false }, { type: "session_settled" }, state])
    expect(@events.last["result"]).to eq("Completed.")
    expect(@writer.string.lines.length).to eq(1)
  end

  it "requests state once when completion signals overlap and accepts local-only legacy hints" do
    run_frames([{ type: "agent_end", isTerminal: true },
      { type: "prompt_result", status: "completed", sessionSettled: true }, { type: "session_settled" }, state])
    expect(@writer.string.lines.length).to eq(1)
    expect(@events.count { |event| event.is_a?(Hash) && event["type"] == "result" }).to eq(1)

    run_frames([{ type: "prompt_result", id: "turn", agentInvoked: false }, state])
    expect(@events.last["result"]).to eq("Completed.")
    expect(@writer.string.lines.length).to eq(1)
  end

  it "stops on budget failure and shows the funding link without retry advice or account metadata" do
    frames = [{ type: "message_end", message: { role: "assistant", stopReason: "error", errorStatus: 402,
      errorMessage: "402 #{credit_error.to_json}" } }, { type: "message_end", message: { role: "toolResult" } },
      { type: "response", success: false, error: "Prompt failed" }]
    expect { run_frames(frames) }.to raise_error(IOError) { |error|
      expect(error.message).to eq(funding_prompt)
      expect(error).to be_a(described_class::BudgetError)
      expect(error.message).not_to include("sign-in", "private-metadata", "private-account", "user_id", "Retry", "retry", "120")
    }
  end

  it "reads structured command and frame errors as well as JSON error strings" do
    [credit_error, credit_error.to_json, "402 #{credit_error.to_json}"].each do |detail|
      expect { run_frames([{ type: "rpc_frame_error", error: detail }]) }.to raise_error(described_class::BudgetError, funding_prompt)
    end
    expect { run_frames([{ type: "response", success: false, error: { message: "Model unavailable", code: 404 } }]) }
      .to raise_error(IOError, "Oh My Pi request failed (HTTP 404): Model unavailable")
    expect { run_frames([{ type: "rpc_frame_error", message: "Invalid RPC command" }]) }
      .to raise_error(IOError, "Oh My Pi request failed: Invalid RPC command")
  end

  it "supports newer OMP retry hints and failed turns or disconnects after a model error" do
    failed_message = { type: "message_end", message: { role: "assistant", stopReason: "error",
      errorMessage: "503 Service unavailable. retry-after-ms=120001" } }
    expect { run_frames([failed_message, { type: "prompt_result", status: "error" }]) }
      .to raise_error(IOError, "Oh My Pi turn did not complete (HTTP 503): Service unavailable. Retry after 121 seconds.")
    expect { run_frames([failed_message, { type: "prompt_result", status: "completed" }]) }
      .to raise_error(IOError, /HTTP 503/)
    expect { run_frames([failed_message]) }.to raise_error(IOError, /request failed \(HTTP 503\)/)
    expect { run_frames([{ type: "prompt_result", status: "error", errorMessage: "Model access denied" }]) }
      .to raise_error(IOError, "Oh My Pi turn did not complete: Model access denied")
  end

  it "allows OMP to recover through its own retry before reporting a successful completion" do
    run_frames([{ type: "message_end" },
      { type: "message_end", message: { role: "assistant", stopReason: "error", errorMessage: "429 Retry later" } },
      { type: "agent_end", isTerminal: false },
      { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "Recovered" } },
      { type: "message_end", message: { role: "assistant", stopReason: "stop" } },
      { type: "agent_end", isTerminal: true },
      { type: "prompt_result", status: "completed", sessionSettled: true }, state])
    expect(@events.last["result"]).to eq("Recovered")
  end

  it "reports terminal agent errors without waiting for an older prompt_result frame" do
    expect { run_frames([
      { type: "message_end", message: { role: "assistant", stopReason: "error", errorMessage: "503 Provider unavailable" } },
      { type: "agent_end", isTerminal: true }
    ]) }.to raise_error(IOError, "Oh My Pi request failed (HTTP 503): Provider unavailable")
  end

  it "interrupts OMP's budget retry at message_end even without a terminal event" do
    expect { run_frames([
      { type: "ready" },
      { type: "message_end", message: { role: "assistant", stopReason: "error", errorMessage: "402 Credits exhausted retry-after-ms=120000" } },
      { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "Should never retry" } }
    ]) }.to raise_error(described_class::BudgetError, funding_prompt)
    expect(@writer.string.lines.length).to eq(1)
    expect(@events).to be_empty
  end

  it "only links to OpenRouter when the selected source or error identifies it" do
    expect { run_frames([{ type: "response", success: false, error: credit_error }], provider: "native") }
      .to raise_error(described_class::BudgetError, funding_prompt)
    expect { run_frames([{ type: "response", success: false, error: { metadata: { reason: "in_flight_budget_exhausted" } } }], provider: "native") }
      .to raise_error(described_class::BudgetError, funding_prompt)
    expect { run_frames([{ type: "response", success: false, error: { code: 402, message: "Insufficient funds" } }], provider: "custom") }
      .to raise_error(described_class::BudgetError, "Model provider budget exhausted. Add credits or increase the provider budget to continue.")
  end

  it "redacts credentials, URLs and control characters and bounds displayed error text" do
    original = ENV["RELAY_TEST_SECRET"]
    ENV["RELAY_TEST_SECRET"] = "fixture-private-value"
    detail = "Denied fixture-private-value Bearer bearer-credential sk-secret-key api_key=other-key token:other-token " \
      "password='other-password' https://user:password@example.test/?key=secret\n\e[31m"
    expect { run_frames([{ type: "response", success: false, error: detail }]) }.to raise_error(IOError) { |error|
      expect(error.message).to include("Denied [REDACTED] Bearer [REDACTED]", "api_key=[REDACTED]", "token:[REDACTED]", "password='[REDACTED]", "[URL omitted]")
      expect(error.message).not_to include("fixture-private-value", "bearer-credential", "sk-secret-key", "other-key", "other-token", "other-password", "example.test", "\n", "\e")
    }
    expect { run_frames([{ type: "rpc_frame_error", error: "x" * 1000 }]) }.to raise_error(IOError) { |error|
      expect(error.message).to eq("Oh My Pi request failed: #{'x' * 500}")
    }
  ensure
    ENV["RELAY_TEST_SECRET"] = original
  end

  it "handles unknown or malformed error payloads without exposing raw JSON" do
    [[], "null", "[]", '{"secret":"hidden"', { message: { private: "hidden" } }, { metadata: "bad" },
      { metadata: { headers: "bad" }, code: "not-an-http-status" }].each do |detail|
      expect { run_frames([{ type: "response", success: false, error: detail }]) }
        .to raise_error(IOError, "Oh My Pi request failed.")
    end
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
