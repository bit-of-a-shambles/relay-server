# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/event_bus"
require "relay_daemon/pairing_service"
require "relay_daemon/repo_store"
require "relay_daemon/task_store"
require "relay_daemon/ws_handler"
require "socket"
require "stringio"

RSpec.describe RelayDaemon::EventBus do
  subject(:bus) { described_class.new }

  it "delivers published events to subscribers" do
    received = []
    bus.subscribe { |e| received << e }
    bus.publish(type: "task.started", task_id: "t1", payload: { "a" => 1 })

    expect(received).to eq([
      { "type" => "task.started", "taskId" => "t1", "payload" => { "a" => 1 } }
    ])
  end

  it "defaults taskId to nil and payload to empty hash" do
    received = []
    bus.subscribe { |e| received << e }
    bus.publish(type: "stats.updated")
    expect(received.first["taskId"]).to be_nil
    expect(received.first["payload"]).to eq({})
  end

  it "stops delivering after unsubscribe" do
    received = []
    id = bus.subscribe { |e| received << e }
    bus.unsubscribe(id)
    bus.publish(type: "task.started")
    expect(received).to be_empty
  end

  it "a raising subscriber does not block delivery to others" do
    received = []
    bus.subscribe { |_e| raise "boom" }
    bus.subscribe { |e| received << e }
    expect { bus.publish(type: "task.started") }.not_to raise_error
    expect(received.length).to eq(1)
  end
end

# Minimal stand-in for a Faye::WebSocket connection.
class FakeWs
  attr_reader :sent, :close_code

  def initialize
    @sent = []
    @close_code = nil
    @handlers = {}
  end

  def send(msg)
    @sent << msg
  end

  def close(code = nil)
    @close_code = code
    @handlers[:close]&.call
  end

  def on(event, &block)
    @handlers[event] = block
  end

  def rack_response
    [200, {}, []]
  end
end

RSpec.describe RelayDaemon::WsHandler do
  let(:bus) { RelayDaemon::EventBus.new }

  describe ".attach" do
    it "forwards bus events as JSON frames when authorized" do
      ws = FakeWs.new
      described_class.attach(ws, authorized: true, bus: bus)
      bus.publish(type: "task.started", task_id: "t1")

      expect(ws.sent.length).to eq(1)
      expect(JSON.parse(ws.sent.first)).to eq(
        { "type" => "task.started", "taskId" => "t1", "payload" => {} }
      )
    end

    it "unsubscribes when the socket closes" do
      ws = FakeWs.new
      described_class.attach(ws, authorized: true, bus: bus)
      ws.close
      bus.publish(type: "task.started")
      expect(ws.sent).to be_empty
    end

    it "closes with 4401 when not authorized" do
      ws = FakeWs.new
      described_class.attach(ws, authorized: false, bus: bus)
      expect(ws.close_code).to eq(4401)
      bus.publish(type: "task.started")
      expect(ws.sent).to be_empty
    end
  end

  describe ".token_authorized?" do
    it "accepts the static daemon token" do
      expect(described_class.token_authorized?("secret", static_token: "secret", pairing: nil)).to be true
    end

    it "rejects a wrong token with no pairing service" do
      expect(described_class.token_authorized?("wrong", static_token: "secret", pairing: nil)).to be false
    end

    it "rejects when no static token and no pairing service" do
      expect(described_class.token_authorized?("anything", static_token: nil, pairing: nil)).to be false
    end

    it "rejects when the static token is empty" do
      expect(described_class.token_authorized?("", static_token: "", pairing: nil)).to be false
    end

    it "accepts a valid paired token" do
      db = RelayDaemon::Db.new(File.join(Dir.mktmpdir, "ws.sqlite3"))
      service = RelayDaemon::PairingService.new(db)
      token = service.claim(service.start_pairing)
      expect(described_class.token_authorized?(token, static_token: nil, pairing: service)).to be true
      expect(described_class.token_authorized?("bad", static_token: nil, pairing: service)).to be false
      db.connection.close
    end
  end
end

RSpec.describe RelayDaemon::FayeUpgrader do
  def ws_env(io)
    env = {
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/ws",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7777",
      "HTTP_HOST" => "localhost:7777",
      "HTTP_CONNECTION" => "Upgrade",
      "HTTP_UPGRADE" => "websocket",
      "HTTP_SEC_WEBSOCKET_VERSION" => "13",
      "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new,
      "rack.errors" => StringIO.new,
      "rack.hijack?" => true
    }
    # Per the Rack hijack spec, calling rack.hijack sets rack.hijack_io.
    env["rack.hijack"] = lambda do
      env["rack.hijack_io"] = io
      io
    end
    env
  end

  it "recognizes a websocket upgrade request" do
    io, peer = UNIXSocket.pair
    expect(described_class.upgrade?(ws_env(io))).to be true
    io.close
    peer.close
  end

  it "does not recognize a plain HTTP request" do
    expect(described_class.upgrade?({ "REQUEST_METHOD" => "GET" })).to be false
  end

  it "upgrades a hijackable request to a websocket" do
    io, peer = UNIXSocket.pair
    ws = described_class.upgrade(ws_env(io))
    expect(ws).to respond_to(:rack_response)
    # faye-websocket starts an EventMachine reactor thread lazily;
    # wait for it before closing or EM raises "not initialized".
    deadline = Time.now + 5
    sleep 0.01 until EventMachine.reactor_running? || Time.now > deadline
    ws.close
    io.close
    peer.close
  end
end

RSpec.describe "WS route and lifecycle events" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:db_path)       { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)            { RelayDaemon::Db.new(db_path) }
  let(:repo_store)    { RelayDaemon::RepoStore.new(db) }
  let(:task_store)    { RelayDaemon::TaskStore.new(db) }
  let(:token)         { "events-test-token" }
  let(:worktrees_dir) { Dir.mktmpdir }
  let(:agent_log_dir) { Dir.mktmpdir }
  let(:bus)           { RelayDaemon::EventBus.new }
  let(:git_dir)       { make_git_dir }
  let(:repo)          { repo_store.create(path: git_dir) }

  let(:fake_agent) { File.expand_path("support/fake_agent.rb", __dir__) }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
      worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
      agent_command: "ruby #{fake_agent} {prompt}"
    ))
    RelayDaemon::App.set(:repo_store, repo_store)
    RelayDaemon::App.set(:task_store, task_store)
    RelayDaemon::App.set(:event_bus, bus)
    RelayDaemon::App.set(:ws_upgrader, RelayDaemon::FayeUpgrader)
  end

  after { db.connection.close }

  def auth_headers
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def run_task(quality: 5, agent_args: "")
    post "/tasks",
         { repoId: repo["id"], prompt: "do it", qualityDial: quality }.to_json,
         { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
    task_id = JSON.parse(last_response.body)["id"]
    deadline = Time.now + 10
    loop do
      get "/tasks/#{task_id}", {}, auth_headers
      t = JSON.parse(last_response.body)
      break t if %w[needs_review failed].include?(t["status"])
      raise "timeout" if Time.now > deadline

      sleep 0.05
    end
  end

  describe "GET /ws" do
    it "returns 400 for a plain HTTP request" do
      get "/ws?token=#{token}"
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]).to include("upgrade")
    end

    it "upgrades and attaches via an injected fake upgrader" do
      fake_ws = FakeWs.new
      fake_upgrader = Class.new do
        define_singleton_method(:upgrade?) { |_env| true }
      end
      fake_upgrader.define_singleton_method(:upgrade) { |_env| fake_ws }
      RelayDaemon::App.set(:ws_upgrader, fake_upgrader)

      get "/ws?token=#{token}"
      expect(last_response.status).to eq(200)

      bus.publish(type: "task.started", task_id: "t1")
      expect(fake_ws.sent.length).to eq(1)
    end

    it "closes with 4401 via the fake upgrader when token is wrong" do
      fake_ws = FakeWs.new
      fake_upgrader = Class.new do
        define_singleton_method(:upgrade?) { |_env| true }
      end
      fake_upgrader.define_singleton_method(:upgrade) { |_env| fake_ws }
      RelayDaemon::App.set(:ws_upgrader, fake_upgrader)

      get "/ws?token=wrong"
      expect(fake_ws.close_code).to eq(4401)
    end
  end

  describe "lifecycle publications" do
    it "publishes task.started, agent.event lines, task.needs_review, stats.updated" do
      events = []
      bus.subscribe { |e| events << e }
      task = run_task

      types = events.map { |e| e["type"] }
      expect(types).to include("task.started", "agent.event", "task.needs_review", "stats.updated")

      lines = events.select { |e| e["type"] == "agent.event" }.map { |e| e["payload"]["line"] }
      expect(lines).to include("agent line one", "agent line two")

      review = events.find { |e| e["type"] == "task.needs_review" }
      expect(review["taskId"]).to eq(task["id"])

      # Ordering: started before agent events before needs_review
      expect(types.index("task.started")).to be < types.index("agent.event")
      expect(types.rindex("agent.event")).to be < types.index("task.needs_review")
    end

    it "publishes task.finished with status failed when the agent crashes" do
      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
        worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
        agent_command: "ruby #{fake_agent} {prompt} 1"
      ))
      events = []
      bus.subscribe { |e| events << e }
      run_task

      finished = events.find { |e| e["type"] == "task.finished" }
      expect(finished["payload"]["status"]).to eq("failed")
      expect(events.map { |e| e["type"] }).to include("stats.updated")
    end

    it "publishes task.finished with status approved on approve" do
      task = run_task
      events = []
      bus.subscribe { |e| events << e }

      post "/tasks/#{task["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(200)

      finished = events.find { |e| e["type"] == "task.finished" }
      expect(finished["payload"]["status"]).to eq("approved")
      expect(finished["taskId"]).to eq(task["id"])
      expect(events.map { |e| e["type"] }).to include("stats.updated")
    end

    it "publishes task.finished with status rejected on reject" do
      task = run_task
      events = []
      bus.subscribe { |e| events << e }

      post "/tasks/#{task["id"]}/reject", "", auth_headers
      expect(last_response.status).to eq(200)

      finished = events.find { |e| e["type"] == "task.finished" }
      expect(finished["payload"]["status"]).to eq("rejected")
    end
  end
end
