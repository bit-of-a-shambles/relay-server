# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "relay_daemon/event_bus"
require "relay_daemon/repo_store"
require "relay_daemon/push_notifier"
require "relay_daemon/session_runner"
require "relay_daemon/session_store"
require "timeout"

class SessionPushHttp
  include RelayDaemon::PushHttp

  attr_reader :requests

  def initialize
    @requests = []
  end

  def post(uri, body, headers, timeout)
    @requests << { uri: uri, body: body, headers: headers, timeout: timeout }
    200
  end
end

class SessionBlockingPushHttp
  include RelayDaemon::PushHttp

  attr_reader :started, :release

  def initialize
    @started = Queue.new
    @release = Queue.new
  end

  def post(_uri, _body, _headers, _timeout)
    @started << true
    @release.pop
    200
  end
end

RSpec.describe RelayDaemon::SessionRunner do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db) { RelayDaemon::Db.new(db_path) }
  let(:repo_store) { RelayDaemon::RepoStore.new(db) }
  let(:session_store) { RelayDaemon::SessionStore.new(db) }
  let(:message_store) { RelayDaemon::MessageStore.new(db, session_store) }
  let(:repo) { repo_store.create(path: make_git_dir) }
  let(:worktrees_dir) { Dir.mktmpdir }
  let(:sessions_log_dir) { Dir.mktmpdir }
  let(:session_id) { "11111111-1111-4111-8111-111111111111" }
  let(:session) { session_store.create(repo: repo, worktrees_dir: worktrees_dir, id: session_id) }
  let(:worktree_path) { File.join(worktrees_dir, session["id"]) }
  let(:event_bus) { RelayDaemon::EventBus.new }
  let(:agent_command) { "ruby #{File.expand_path("support/fake_session_agent.rb", __dir__)} {prompt}" }

  after { db.connection.close }

  def run_message(content)
    described_class.run_async(
      session_id: session["id"],
      content: content,
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: agent_command,
      db_path: db_path,
      event_bus: event_bus
    ).join
  end

  it "adds streaming flags only to opted-in Claude commands without an output format" do
    base = ["/opt/homebrew/bin/claude", "-p", "hello"]
    expect(described_class.enable_claude_streaming(base, enabled: true)).to eq(
      base + ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
    )
    expect(described_class.enable_claude_streaming(base, enabled: false)).to eq(base)
    expect(described_class.enable_claude_streaming(["custom-agent"], enabled: true)).to eq(["custom-agent"])
    expect(
      described_class.enable_claude_streaming(base + ["--output-format=stream-json"], enabled: true)
    ).to eq(base + ["--output-format=stream-json"])
    expect(
      described_class.enable_claude_streaming(base + ["--output-format", "json"], enabled: true)
    ).to eq(base + ["--output-format", "json"])
  end

  def run_agent_output(output, content: "stream", run_id: "stream-run", stream_json: false, stderr: nil)
    script_dir = Dir.mktmpdir
    script = File.join(script_dir, "agent.rb")
    script_body = "STDOUT.write(#{output.inspect})"
    script_body += "; STDERR.write(#{stderr.inspect})" if stderr
    File.write(script, script_body)
    argv = ["ruby", script]
    argv += ["--output-format", "stream-json"] if stream_json
    described_class.run_async(
      session_id: session["id"],
      content: content,
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: argv,
      db_path: db_path,
      event_bus: event_bus,
      run_id: run_id
    ).join
  end

  it "uses --session-id for the first message and --resume for the second" do
    run_message("hello")
    run_message("again")

    messages = message_store.list_for_session(session["id"])
    expect(messages.map { |message| message["role"] }).to eq(
      %w[user assistant user assistant]
    )
    expect(messages[1]["content"]).to include("mode=session-id", "token=#{session["id"]}", "prompt=hello")
    expect(messages[3]["content"]).to include("mode=resume", "token=#{session["id"]}", "prompt=again")
    expect(messages.map { |message| message["agentRunId"] }.compact.uniq.length).to eq(2)

    run_lines = File.read(File.join(worktree_path, "session_agent_runs.txt")).lines.map(&:chomp)
    expect(run_lines).to eq([
      "session-id:#{session["id"]}:hello",
      "resume:#{session["id"]}:again"
    ])
  end

  it "writes a per-run log and publishes session-scoped agent events" do
    events = []
    event_bus.subscribe { |event| events << event }

    run_message("log me")

    logs = Dir.glob(File.join(sessions_log_dir, session["id"], "runs", "*.log"))
    expect(logs.length).to eq(1)
    expect(File.read(logs.first)).to include("prompt=log me")
    agent_events = events.select { |event| event["type"] == "agent.event" }
    expect(agent_events.map { |event| event["payload"]["sessionId"] }.uniq).to eq([session["id"]])
    expect(agent_events.map { |event| event["payload"]["line"] }).to include("prompt=log me")
  end

  it "publishes cumulative top-level previews and persists the terminal result" do
    events = []
    event_bus.subscribe { |event| events << event }
    output = [
      { "type" => "system", "subtype" => "init" },
      {
        "type" => "stream_event",
        "event" => {
          "type" => "content_block_delta",
          "delta" => { "type" => "text_delta", "text" => "Hello" }
        }
      },
      {
        "type" => "stream_event",
        "parent_tool_use_id" => "subagent-1",
        "event" => {
          "type" => "content_block_delta",
          "delta" => { "type" => "text_delta", "text" => " hidden" }
        }
      },
      {
        "type" => "stream_event",
        "event" => {
          "type" => "content_block_delta",
          "delta" => { "type" => "thinking_delta", "thinking" => "secret" }
        }
      },
      {
        "type" => "stream_event",
        "event" => {
          "type" => "content_block_delta",
          "delta" => { "type" => "input_json_delta", "partial_json" => "{}" }
        }
      },
      "{malformed json",
      {
        "type" => "stream_event",
        "event" => {
          "type" => "content_block_delta",
          "delta" => { "type" => "text_delta", "text" => " world" }
        }
      },
      {
        "type" => "assistant",
        "message" => {
          "content" => [
            { "type" => "thinking", "thinking" => "secret" },
            { "type" => "text", "text" => "First complete answer" },
            { "type" => "tool_use", "input" => {} }
          ]
        }
      },
      {
        "type" => "assistant",
        "message" => { "content" => [{ "type" => "text", "text" => "Last complete answer" }] }
      },
      { "type" => "result", "result" => "Canonical result" },
      { "type" => "diagnostic", "message" => "ignored as protocol output" }
    ].map { |line| line.is_a?(String) ? line : JSON.generate(line) }.join("\n") + "\n"

    run_agent_output(output, stream_json: true)

    agent_events = events.select { |event| event["type"] == "agent.event" }
    updates = events.select { |event| event["type"] == "assistant.updated" }
    expect(agent_events.map { |event| event["payload"]["line"] }).to eq([
      "{malformed json",
      '{"type":"diagnostic","message":"ignored as protocol output"}'
    ])
    expect(updates.map { |event| event["payload"] }).to eq([
      { "sessionId" => session["id"], "agentRunId" => "stream-run", "sequence" => 0, "content" => "Hello" },
      { "sessionId" => session["id"], "agentRunId" => "stream-run", "sequence" => 1, "content" => "Hello world" }
    ])
    expect(events.map { |event| event["type"] }).to eq([
      "assistant.updated", "agent.event", "assistant.updated", "agent.event", "message.created", "session.updated"
    ])

    message = message_store.list_for_session(session["id"]).last
    expect(message).to include(
      "role" => "assistant", "content" => "Canonical result", "agentRunId" => "stream-run"
    )
    expect(events[-2]).to eq(
      "type" => "message.created",
      "payload" => { "sessionId" => session["id"], "message" => message }
    )
    log = Dir.glob(File.join(sessions_log_dir, session["id"], "runs", "*.log" )).first
    expect(File.read(log)).to include("{malformed json", '"type":"diagnostic"')
  end

  it "persists semantic assistant content when no deltas are available" do
    events = []
    event_bus.subscribe { |event| events << event }
    output = JSON.generate(
      "type" => "assistant",
      "content" => [
        { "type" => "text", "text" => "Final answer" },
        { "type" => "tool_use", "name" => "ignored" }
      ]
    ) + "\n"

    run_agent_output(output, content: "final", run_id: "final-run", stream_json: true)

    message = message_store.list_for_session(session["id"]).last
    expect(message["content"]).to eq("Final answer")
    expect(events.map { |event| event["type"] }).to eq(["message.created", "session.updated"])
    expect(events.first["payload"]["message"]).to eq(message)
  end

  it "uses a semantic result as the final assistant fallback" do
    events = []
    event_bus.subscribe { |event| events << event }
    run_agent_output(
      JSON.generate("type" => "result", "result" => "Result text") + "\n",
      content: "result",
      run_id: "result-run",
      stream_json: true
    )

    message = message_store.list_for_session(session["id"]).last
    expect(message["content"]).to eq("Result text")
    expect(events.map { |event| event["type"] }).to eq(["message.created", "session.updated"])
  end

  it "keeps JSON-looking output verbatim for commands without stream-json" do
    output = "{\"answer\":42}\n[\"one\",2]\n"
    events = []
    event_bus.subscribe { |event| events << event }

    run_agent_output(output, content: "plain json", run_id: "plain-json-run")

    expect(message_store.list_for_session(session["id"]).last["content"])
      .to eq("{\"answer\":42}\n[\"one\",2]")
    expect(events.select { |event| event["type"] == "agent.event" }
      .map { |event| event["payload"]["line"] }).to eq(["{\"answer\":42}", "[\"one\",2]"])
  end

  it "keeps stream protocol stdout out of diagnostics while publishing stderr diagnostics" do
    events = []
    event_bus.subscribe { |event| events << event }
    output = JSON.generate(
      "type" => "stream_event",
      "event" => {
        "type" => "content_block_delta",
        "delta" => { "type" => "text_delta", "text" => "visible" }
      }
    ) + "\n"

    run_agent_output(output, run_id: "stderr-run", stream_json: true, stderr: "diagnostic\n")

    expect(events.select { |event| event["type"] == "agent.event" }
      .map { |event| event["payload"]["line"] }).to eq(["diagnostic"])
    expect(message_store.list_for_session(session["id"]).last["content"]).to eq("visible")
  end

  it "uses malformed stream output as a visible plain fallback and retains the raw log" do
    events = []
    event_bus.subscribe { |event| events << event }
    run_agent_output("{not valid stream json\n", content: "bad stream", run_id: "bad-stream", stream_json: true)

    expect(message_store.list_for_session(session["id"]).last["content"]).to eq("{not valid stream json")
    expect(events.select { |event| event["type"] == "agent.event" }
      .map { |event| event["payload"]["line"] }).to eq(["{not valid stream json"])
    log = Dir.glob(File.join(sessions_log_dir, session["id"], "runs", "*.log" )).first
    expect(File.read(log)).to include("{not valid stream json")
  end

  it "keeps known Claude auth advisories out of live output and assistant messages" do
    events = []
    event_bus.subscribe { |event| events << event }

    described_class.run_async(
      session_id: session["id"],
      content: "quiet warning",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: [
        "ruby",
        "-e",
        "puts 'claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set and takes precedence over your claude.ai login. Unset it to load your organization connectors'; puts 'real agent output'"
      ],
      db_path: db_path,
      event_bus: event_bus
    ).join

    agent_events = events.select { |event| event["type"] == "agent.event" }
    event_lines = agent_events.map { |event| event["payload"]["line"] }
    messages = message_store.list_for_session(session["id"])
    logs = Dir.glob(File.join(sessions_log_dir, session["id"], "runs", "*.log"))

    expect(event_lines).to eq(["real agent output"])
    expect(messages.last["content"]).to eq("real agent output")
    expect(File.read(logs.first)).to include("claude.ai connectors are disabled")
  end

  it "sets session-scoped routing environment for the agent process" do
    described_class.run_async(
      session_id: session["id"],
      content: "env please",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: agent_command,
      db_path: db_path,
      event_bus: event_bus,
      router_base_url: "http://127.0.0.1:7778/api/"
    ).join

    expect(File.read(File.join(worktree_path, "env_session_id.txt"))).to eq(session["id"])
    expect(File.read(File.join(worktree_path, "env_anthropic_base.txt")))
      .to eq("http://127.0.0.1:7778/api/session/#{session["id"]}")
  end

  it "suffixes the routing base url with /escalated when escalated is true" do
    described_class.run_async(
      session_id: session["id"],
      content: "retry please",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: agent_command,
      db_path: db_path,
      event_bus: event_bus,
      router_base_url: "http://127.0.0.1:7778/api/",
      escalated: true
    ).join

    expect(File.read(File.join(worktree_path, "env_anthropic_base.txt")))
      .to eq("http://127.0.0.1:7778/api/session/#{session["id"]}/escalated")
  end

  it "stores a fallback assistant message when the agent produces no output" do
    described_class.run_async(
      session_id: session["id"],
      content: "quiet",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: "true {prompt}",
      db_path: db_path,
      event_bus: event_bus
    ).join

    messages = message_store.list_for_session(session["id"])
    expect(messages.last["role"]).to eq("assistant")
    expect(messages.last["content"]).to eq("Agent exited with status 0")
  end

  it "serializes concurrent messages for the same session" do
    first = described_class.run_async(
      session_id: session["id"],
      content: "slow first",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: agent_command,
      db_path: db_path,
      event_bus: event_bus
    )
    Timeout.timeout(2) { Thread.pass until described_class.running?(session["id"]) }
    second = described_class.run_async(
      session_id: session["id"],
      content: "fast second",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: agent_command,
      db_path: db_path,
      event_bus: event_bus
    )

    [first, second].each(&:join)

    messages = message_store.list_for_session(session["id"])
    expect(messages.map { |message| [message["role"], message["content"]] }).to eq([
      ["user", "slow first"],
      ["assistant", "mode=session-id\ntoken=#{session["id"]}\nprompt=slow first"],
      ["user", "fast second"],
      ["assistant", "mode=resume\ntoken=#{session["id"]}\nprompt=fast second"]
    ])
  end

  it "runs sibling sessions concurrently" do
    sibling = session_store.create(repo: repo, worktrees_dir: worktrees_dir)
    first_gate = File.join(Dir.mktmpdir, "first-gate")
    second_gate = File.join(Dir.mktmpdir, "second-gate")
    first_started = File.join(Dir.mktmpdir, "first-started")
    second_started = File.join(Dir.mktmpdir, "second-started")
    File.mkfifo(first_gate)
    File.mkfifo(second_gate)
    script = File.join(Dir.mktmpdir, "blocking_agent.rb")
    File.write(script, "File.write(ARGV.fetch(0), 'started'); File.open(ARGV.fetch(1), 'r').read; puts 'done'")
    command = ->(started, gate) { ["ruby", script, started, gate, "{prompt}"] }

    first = described_class.run_async(
      session_id: session["id"], content: "first", worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir, agent_command: command.call(first_started, first_gate),
      db_path: db_path, event_bus: event_bus
    )
    second = described_class.run_async(
      session_id: sibling["id"], content: "second", worktree_path: File.join(worktrees_dir, sibling["id"]),
      sessions_log_dir: sessions_log_dir, agent_command: command.call(second_started, second_gate),
      db_path: db_path, event_bus: event_bus
    )

    Timeout.timeout(2) { Thread.pass until File.exist?(first_started) && File.exist?(second_started) }
    expect(described_class.running?(session["id"])).to be true
    expect(described_class.running?(sibling["id"])).to be true
    File.open(first_gate, "w") { |io| io.write("release") }
    File.open(second_gate, "w") { |io| io.write("release") }
    first.join
    second.join
    expect(described_class.running?(session["id"])).to be false
    expect(described_class.running?(sibling["id"])).to be false
  end

  it "reports running? true while a run is in flight and false once it finishes" do
    expect(described_class.running?(session["id"])).to be false

    run = described_class.run_async(
      session_id: session["id"],
      content: "slow running check",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: agent_command,
      db_path: db_path,
      event_bus: event_bus
    )
    sleep 0.05
    expect(described_class.running?(session["id"])).to be true

    run.join
    expect(described_class.running?(session["id"])).to be false
  end

  it "notifies after storing the finished agent run" do
    device_store = RelayDaemon::PushDeviceStore.new(db)
    device_store.create(device_token: "a1" * 8)
    http = SessionPushHttp.new
    notifier = RelayDaemon::PushNotifier.new(
      relay_url: "https://push.example.test/push",
      relay_token: "relay-secret",
      environment: "production",
      device_store: device_store,
      http: http
    )

    described_class.run_async(
      session_id: session["id"],
      content: "notify me",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: agent_command,
      db_path: db_path,
      event_bus: event_bus,
      push_notifier: notifier
    ).join

    expect(notifier.wait_until_idle(timeout: 1.0)).to be true
    expect(http.requests.length).to eq(1)
    expect(JSON.parse(http.requests.first[:body])).to include(
      "deviceToken" => "a1" * 8, "category" => "agent_finished", "environment" => "production"
    )
    expect(notifier.shutdown(timeout: 1.0)).to be true
  end

  it "releases the session lock while background push delivery is blocked" do
    device_store = RelayDaemon::PushDeviceStore.new(db)
    device_store.create(device_token: "a1" * 8)
    http = SessionBlockingPushHttp.new
    notifier = RelayDaemon::PushNotifier.new(
      relay_url: "https://push.example.test/push",
      relay_token: "relay-secret",
      environment: "production",
      device_store: device_store,
      http: http
    )

    run = described_class.run_async(
      session_id: session["id"],
      content: "do not block",
      worktree_path: worktree_path,
      sessions_log_dir: sessions_log_dir,
      agent_command: agent_command,
      db_path: db_path,
      event_bus: event_bus,
      push_notifier: notifier
    )

    expect(Timeout.timeout(2) { run.join }).to eq(run)
    Timeout.timeout(1) { http.started.pop }
    expect(described_class.running?(session["id"])).to be false
    http.release << true
    expect(notifier.shutdown(timeout: 1.0)).to be true
  end

  it "builds argv with resume flags" do
    expect(
      described_class.build_argv("agent {prompt}", "hi", session_id: session["id"], resume: false)
    ).to eq(["agent", "hi", "--session-id", session["id"]])
    expect(
      described_class.build_argv("agent {prompt}", "hi", session_id: session["id"], resume: true)
    ).to eq(["agent", "hi", "--resume", session["id"]])
  end
end
