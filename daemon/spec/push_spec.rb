# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/push_device_store"
require "relay_daemon/push_notifier"
require "relay_daemon/repo_store"
require "relay_daemon/session_store"
require "stringio"
require "timeout"

PUSH_DEVICE_TOKEN_ONE = "a1" * 8
PUSH_DEVICE_TOKEN_TWO = "b2" * 8
PUSH_DEVICE_TOKEN_THREE = "c3" * 8

class RecordingPushHttp
  include RelayDaemon::PushHttp

  attr_reader :requests

  def initialize(statuses: [])
    @requests = []
    @statuses = statuses
  end

  def post(uri, body, headers, timeout)
    @requests << { uri: uri, body: body, headers: headers, timeout: timeout }
    @statuses.shift || 200
  end
end

class FailingPushHttp
  include RelayDaemon::PushHttp

  attr_reader :calls

  def initialize
    @calls = 0
  end

  def post(_uri, _body, _headers, _timeout)
    @calls += 1
    raise "relay unavailable" if @calls == 1

    200
  end
end

class BlockingPushHttp
  include RelayDaemon::PushHttp

  attr_reader :calls, :started, :release

  def initialize
    @calls = 0
    @started = Queue.new
    @release = Queue.new
  end

  def post(_uri, _body, _headers, _timeout)
    @calls += 1
    @started << true
    @release.pop
    200
  end
end

class StalledLockingPushHttp
  include RelayDaemon::PushHttp

  attr_reader :calls, :successful_bodies, :timeouts

  def initialize
    @calls = 0
    @successful_bodies = []
    @timeouts = []
    @lock = Mutex.new
  end

  def post(_uri, body, _headers, timeout)
    @lock.synchronize do
      @calls += 1
      @timeouts << timeout
      if @calls == 1
        sleep(timeout + 0.01)
        raise Net::ReadTimeout
      end

      @successful_bodies << body
      200
    end
  end
end

class RecordingPushLogger
  include RelayDaemon::PushLogger

  attr_reader :messages

  def initialize(raise_on_log: false)
    @messages = []
    @raise_on_log = raise_on_log
  end

  def log(message)
    @messages << message
    raise "logger unavailable" if @raise_on_log
  end
end

class FakeNetHttp
  attr_reader :requests, :ssl_values, :open_timeouts, :read_timeouts, :write_timeouts, :starts, :finishes

  def initialize
    @requests = []
    @ssl_values = []
    @open_timeouts = []
    @read_timeouts = []
    @write_timeouts = []
    @starts = 0
    @finishes = 0
  end

  def use_ssl=(value)
    @ssl_values << value
  end

  def open_timeout=(value)
    @open_timeouts << value
  end

  def read_timeout=(value)
    @read_timeouts << value
  end

  def write_timeout=(value)
    @write_timeouts << value
  end

  def start
    @starts += 1
    yield self
  ensure
    @finishes += 1
  end

  def request(request)
    @requests << request
    Struct.new(:code).new("202")
  end
end

RSpec.describe RelayDaemon::PushDeviceStore do
  let(:db) { RelayDaemon::Db.new(File.join(Dir.mktmpdir, "push.sqlite3")) }
  subject(:store) { described_class.new(db) }

  after do
    db.connection.close
  end

  it "creates and lists device tokens" do
    created = store.create(device_token: PUSH_DEVICE_TOKEN_ONE)

    expect(created["deviceToken"]).to eq(PUSH_DEVICE_TOKEN_ONE)
    expect(created["createdAt"]).to be_a(String)
    expect(store.all).to eq([created])
  end

  it "accepts only even-length hexadecimal device tokens from 16 through 128 characters" do
    expect(store.create(device_token: "ab" * 64)["deviceToken"]).to eq("ab" * 64)

    ["", "ab" * 7, "a" * 17, "ag" * 8, "ab" * 65].each do |invalid|
      expect { store.create(device_token: invalid) }
        .to raise_error(ArgumentError, /deviceToken must be 16..128 even-length hex characters/)
    end
  end

  it "canonicalizes valid tokens to lowercase for create, find, and delete" do
    uppercase = "A1" * 8
    created = store.create(device_token: uppercase)

    expect(created["deviceToken"]).to eq(PUSH_DEVICE_TOKEN_ONE)
    expect(store.create(device_token: PUSH_DEVICE_TOKEN_ONE)).to eq(created)
    expect(store.find(uppercase)).to eq(created)
    expect(store.all).to eq([created])
    expect(store.delete(uppercase)).to be true
    expect(store.delete(PUSH_DEVICE_TOKEN_ONE)).to be false
  end

  it "deletes a token and reports whether it existed" do
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)

    expect(store.delete(PUSH_DEVICE_TOKEN_ONE)).to be true
    expect(store.all).to be_empty
    expect(store.delete(PUSH_DEVICE_TOKEN_ONE)).to be false
    expect { store.delete("invalid") }
      .to raise_error(ArgumentError, /deviceToken must be 16..128 even-length hex characters/)
  end

  it "idempotently preserves an existing device registration" do
    created = store.create(device_token: PUSH_DEVICE_TOKEN_ONE)

    expect(store.create(device_token: PUSH_DEVICE_TOKEN_ONE)).to eq(created)
    expect(store.all).to eq([created])
    expect(store.find(PUSH_DEVICE_TOKEN_TWO)).to be_nil
    expect { store.find("invalid") }
      .to raise_error(ArgumentError, /deviceToken must be 16..128 even-length hex characters/)
  end

  it "limits token reads for bounded delivery batches" do
    [PUSH_DEVICE_TOKEN_ONE, PUSH_DEVICE_TOKEN_TWO, PUSH_DEVICE_TOKEN_THREE].each do |token|
      store.create(device_token: token)
    end

    expect(store.all(limit: 2).map { |device| device["deviceToken"] }).to eq([
      PUSH_DEVICE_TOKEN_ONE, PUSH_DEVICE_TOKEN_TWO
    ])
  end
end

RSpec.describe RelayDaemon::PushNotifier do
  let(:db) { RelayDaemon::Db.new(File.join(Dir.mktmpdir, "notifier.sqlite3")) }
  let(:store) { RelayDaemon::PushDeviceStore.new(db) }

  after do
    @notifiers&.each { |notifier| notifier.shutdown(timeout: 1.0) }
    db.connection.close
  end

  def build_notifier(**options)
    defaults = {
      relay_url: "https://push.example.test/push",
      relay_token: "relay-secret",
      environment: "production",
      device_store: store,
      http: RecordingPushHttp.new,
      logger: RecordingPushLogger.new
    }
    notifier = described_class.new(**defaults.merge(options))
    (@notifiers ||= []) << notifier
    notifier
  end

  it "does nothing when the relay URL is unset" do
    http = RecordingPushHttp.new
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    notifier = build_notifier(relay_url: nil, relay_token: nil, http: http)

    expect(notifier.notify("agent_finished")).to be false

    expect(http.requests).to be_empty
  end

  it "posts the exact payload once per device, including needs_review" do
    http = RecordingPushHttp.new
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    store.create(device_token: PUSH_DEVICE_TOKEN_TWO)
    notifier = build_notifier(environment: "sandbox", http: http)

    expect(notifier.notify("needs_review")).to be true
    expect(notifier.wait_until_idle(timeout: 1.0)).to be true

    expect(http.requests.map { |request| request[:uri].to_s }).to eq([
      "https://push.example.test/push",
      "https://push.example.test/push"
    ])
    expect(http.requests.map { |request| JSON.parse(request[:body]) }).to eq([
      { "deviceToken" => PUSH_DEVICE_TOKEN_ONE, "category" => "needs_review", "environment" => "sandbox" },
      { "deviceToken" => PUSH_DEVICE_TOKEN_TWO, "category" => "needs_review", "environment" => "sandbox" }
    ])
    expect(http.requests.map { |request| request[:timeout] }).to all(be_between(0, 3))
    expect(http.requests.map { |request| request[:headers] }).to eq([
      { "Authorization" => "Bearer relay-secret" },
      { "Authorization" => "Bearer relay-secret" }
    ])
  end

  it "does nothing when the relay token is unset" do
    http = RecordingPushHttp.new
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    notifier = build_notifier(relay_token: nil, http: http)

    expect(notifier.notify("agent_finished")).to be false

    expect(http.requests).to be_empty
  end

  it "swallows one HTTP error and continues with later devices" do
    http = FailingPushHttp.new
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    store.create(device_token: PUSH_DEVICE_TOKEN_TWO)
    logger = RecordingPushLogger.new
    notifier = build_notifier(http: http, logger: logger)

    expect { notifier.notify("tests_finished") }.not_to raise_error
    expect(notifier.wait_until_idle(timeout: 1.0)).to be true
    expect(http.calls).to eq(2)
    expect(logger.messages).to include(match(/delivery failed \(RuntimeError\)/))
    expect(logger.messages.join).not_to include("relay-secret", PUSH_DEVICE_TOKEN_ONE)
  end

  it "swallows URI and store errors" do
    logger = RecordingPushLogger.new
    bad_uri = build_notifier(
      relay_url: "not a valid uri",
      logger: logger
    )
    failing_store = store
    allow(failing_store).to receive(:all).and_raise("database unavailable")
    bad_store = build_notifier(
      device_store: failing_store,
      logger: logger
    )

    expect { bad_uri.notify("agent_finished") }.not_to raise_error
    expect { bad_store.notify("agent_finished") }.not_to raise_error
    expect(bad_uri.wait_until_idle(timeout: 1.0)).to be true
    expect(bad_store.wait_until_idle(timeout: 1.0)).to be true
    expect(logger.messages).to all(match(/push worker failed \((URI::InvalidURIError|RuntimeError)\)/))
  end

  it "uses native timeouts and block-scoped HTTP cleanup for both schemes" do
    fake_http = FakeNetHttp.new
    allow(Net::HTTP).to receive(:new).and_return(fake_http)
    adapter = RelayDaemon::NetPushHttp.new

    headers = { "Authorization" => "Bearer relay-secret" }
    expect(adapter.post(URI.parse("http://push.example.test/push"), "{}", headers, 3)).to eq(202)
    expect(adapter.post(URI.parse("https://push.example.test/push"), "{}", headers, 3)).to eq(202)

    expect(fake_http.ssl_values).to eq([false, true])
    expect(fake_http.open_timeouts).to eq([3, 3])
    expect(fake_http.read_timeouts).to eq([3, 3])
    expect(fake_http.write_timeouts).to eq([3, 3])
    expect(fake_http.starts).to eq(2)
    expect(fake_http.finishes).to eq(2)
    expect(fake_http.requests.map { |request| request["Content-Type"] }).to eq([
      "application/json", "application/json"
    ])
    expect(fake_http.requests.map { |request| request["Authorization"] }).to eq([
      "Bearer relay-secret", "Bearer relay-secret"
    ])
    expect(fake_http.requests.map(&:body)).to eq(["{}", "{}"])

    allow(fake_http).to receive(:request).and_raise(Net::ReadTimeout)
    expect { adapter.post(URI.parse("https://push.example.test/push"), "{}", headers, 3) }
      .to raise_error(Net::ReadTimeout)
    expect(fake_http.starts).to eq(3)
    expect(fake_http.finishes).to eq(3)
  end

  it "logs non-2xx responses without tokens and constrains categories" do
    logger = RecordingPushLogger.new
    http = RecordingPushHttp.new(statuses: [503])
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    notifier = build_notifier(http: http, logger: logger)

    expect(notifier.notify("unknown-secret-category")).to be false
    expect(notifier.notify(RelayDaemon::PushNotifier::AGENT_FINISHED)).to be true
    expect(notifier.wait_until_idle(timeout: 1.0)).to be true

    expect(RelayDaemon::PushNotifier::CATEGORIES).to contain_exactly(
      "agent_finished", "tests_finished", "needs_review"
    )
    expect(logger.messages).to include(
      "ignored invalid push category",
      "push relay returned HTTP 503 for agent_finished"
    )
    expect(logger.messages.join).not_to include(
      "unknown-secret-category", "relay-secret", PUSH_DEVICE_TOKEN_ONE
    )
  end

  it "returns promptly, bounds the queue, and exposes idle waiting" do
    logger = RecordingPushLogger.new
    http = BlockingPushHttp.new
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    notifier = build_notifier(http: http, logger: logger, queue_capacity: 1)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(notifier.notify("agent_finished")).to be true
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    expect(elapsed).to be < 0.1
    Timeout.timeout(1) { http.started.pop }

    expect(notifier.notify("tests_finished")).to be true
    expect(notifier.notify("needs_review")).to be false
    expect(notifier.wait_until_idle(timeout: 0.01)).to be false
    expect(logger.messages).to include("push queue full; dropped needs_review")

    2.times { http.release << true }
    expect(notifier.wait_until_idle(timeout: 1.0)).to be true
    expect(http.calls).to eq(2)
  end

  it "caps devices and stops starting deliveries when its monotonic budget expires" do
    logger = RecordingPushLogger.new
    [PUSH_DEVICE_TOKEN_ONE, PUSH_DEVICE_TOKEN_TWO, PUSH_DEVICE_TOKEN_THREE].each do |token|
      store.create(device_token: token)
    end
    capped_http = RecordingPushHttp.new
    capped = build_notifier(http: capped_http, logger: logger, max_devices_per_event: 2)

    expect(capped.notify("agent_finished")).to be true
    expect(capped.wait_until_idle(timeout: 1.0)).to be true
    expect(capped_http.requests.length).to eq(2)
    expect(logger.messages).to include("push device limit reached; remaining devices skipped")

    timeout_http = StalledLockingPushHttp.new
    timed = build_notifier(
      http: timeout_http,
      logger: logger,
      delivery_budget_seconds: 0.05
    )
    expect(timed.notify("tests_finished")).to be true
    expect(timed.wait_until_idle(timeout: 1.0)).to be true
    expect(timeout_http.calls).to eq(1)
    expect(logger.messages).to include("push delivery budget exceeded for tests_finished")

    expect(timed.notify("agent_finished")).to be true
    expect(timed.wait_until_idle(timeout: 1.0)).to be true
    expect(timeout_http.calls).to eq(4)
    expect(timeout_http.successful_bodies.map { |body| JSON.parse(body).fetch("category") })
      .to eq(["agent_finished", "agent_finished", "agent_finished"])
    expect(timeout_http.timeouts).to all(be_between(0, 0.05))
  end

  it "shuts down safely, closes the worker connection, and tolerates logger failure" do
    logger = RecordingPushLogger.new(raise_on_log: true)
    http = RecordingPushHttp.new(statuses: [500])
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    allow(store).to receive(:close_current_connection).and_call_original
    notifier = build_notifier(http: http, logger: logger)

    expect(notifier.notify("agent_finished")).to be true
    expect(notifier.wait_until_idle(timeout: 1.0)).to be true
    expect(notifier.shutdown(timeout: 1.0)).to be true
    expect(store).to have_received(:close_current_connection)
    expect(notifier.notify("agent_finished")).to be false
    expect(notifier.shutdown(timeout: 1.0)).to be true
  end

  it "swallows unexpected enqueue and worker cleanup errors with redacted diagnostics" do
    logger = RecordingPushLogger.new
    notifier = build_notifier(logger: logger)
    queue = notifier.instance_variable_get(:@queue)
    allow(queue).to receive(:push).and_raise("must not appear")

    expect(notifier.notify("agent_finished")).to be false
    expect(logger.messages).to include("push enqueue failed (RuntimeError)")
    expect(logger.messages.join).not_to include("must not appear", "relay-secret")

    allow(store).to receive(:close_current_connection).and_raise("secret cleanup details")
    expect(notifier.shutdown(timeout: 1.0)).to be true
    expect(logger.messages).to include("push worker cleanup failed (RuntimeError)")
    expect(logger.messages.join).not_to include("secret cleanup details")
  end

  it "reports a shutdown timeout without blocking indefinitely" do
    logger = RecordingPushLogger.new
    http = BlockingPushHttp.new
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    notifier = build_notifier(http: http, logger: logger)

    expect(notifier.notify("agent_finished")).to be true
    Timeout.timeout(1) { http.started.pop }
    expect(notifier.shutdown(timeout: 0)).to be false
    expect(logger.messages).to include("push worker did not stop before shutdown timeout")
    http.release << true
    expect(notifier.shutdown(timeout: 1.0)).to be true
  end

  it "writes default diagnostics without including request data" do
    output = StringIO.new
    logger = RelayDaemon::StderrPushLogger.new(output)
    logger.log("fixed diagnostic")
    expect(output.string).to eq("daemon: fixed diagnostic\n")
  end
end

RSpec.describe "push device routes and test completion hook" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:token) { "push-route-token" }
  let(:db_path) { File.join(Dir.mktmpdir, "push-routes.sqlite3") }
  let(:db) { RelayDaemon::Db.new(db_path) }
  let(:store) { RelayDaemon::PushDeviceStore.new(db) }
  let(:config) do
    RelayDaemon::Config.new(
      daemon_token: token,
      host: "127.0.0.1",
      port: 7777,
      db_path: db_path,
      worktrees_dir: Dir.mktmpdir,
      agent_log_dir: Dir.mktmpdir
    )
  end

  before do
    RelayDaemon::App.set(:relay_config, config)
    RelayDaemon::App.set(:stats_db, db)
    RelayDaemon::App.set(:repo_store, RelayDaemon::RepoStore.new(db))
    RelayDaemon::App.set(:session_store, RelayDaemon::SessionStore.new(db))
    RelayDaemon::App.set(:push_device_store, store)
    RelayDaemon::App.set(:push_notifier, nil)
  end

  after do
    notifier = RelayDaemon::App.settings.push_notifier
    notifier.shutdown(timeout: 1.0) if notifier.is_a?(RelayDaemon::PushNotifier)
    db.connection.close
    RelayDaemon::App.set(:push_notifier, nil)
    RelayDaemon::App.set(:push_device_store, nil)
  end

  def auth_headers
    { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  it "requires authentication and a valid device token" do
    post "/push/devices", { deviceToken: PUSH_DEVICE_TOKEN_ONE }.to_json, "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(401)

    post "/push/devices", "not json", auth_headers
    expect(last_response.status).to eq(400)

    post "/push/devices", [].to_json, auth_headers
    expect(last_response.status).to eq(422)

    ["", "ab" * 7, "a" * 17, "ag" * 8, "ab" * 65].each do |invalid|
      post "/push/devices", { deviceToken: invalid }.to_json, auth_headers
      expect(last_response.status).to eq(422)
    end

    post "/push/devices", { deviceToken: "ab" * 300 }.to_json, auth_headers
    expect(last_response.status).to eq(413)
  end

  it "creates and deletes an authenticated device" do
    uppercase = PUSH_DEVICE_TOKEN_ONE.upcase
    post "/push/devices", { deviceToken: uppercase }.to_json, auth_headers
    expect(last_response.status).to eq(201)
    created = JSON.parse(last_response.body)
    expect(created["deviceToken"]).to eq(PUSH_DEVICE_TOKEN_ONE)

    post "/push/devices", { deviceToken: PUSH_DEVICE_TOKEN_ONE }.to_json, auth_headers
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq(created)
    expect(store.all).to eq([created])

    delete "/push/devices/#{uppercase}", {}, auth_headers
    expect(last_response.status).to eq(204)
    delete "/push/devices/#{PUSH_DEVICE_TOKEN_ONE}", {}, auth_headers
    expect(last_response.status).to eq(404)
    delete "/push/devices/invalid", {}, auth_headers
    expect(last_response.status).to eq(422)
  end

  it "returns 503 when the device store is not configured" do
    RelayDaemon::App.set(:push_device_store, nil)

    post "/push/devices", { deviceToken: PUSH_DEVICE_TOKEN_ONE }.to_json, auth_headers
    expect(last_response.status).to eq(503)
    delete "/push/devices/#{PUSH_DEVICE_TOKEN_ONE}", {}, auth_headers
    expect(last_response.status).to eq(503)
  end

  it "notifies when tests complete without a test command" do
    repo = RelayDaemon::RepoStore.new(db).create(path: make_git_dir)
    session = RelayDaemon::SessionStore.new(db).create(repo: repo, worktrees_dir: config.worktrees_dir)
    notifier = instance_double(RelayDaemon::PushNotifier)
    allow(notifier).to receive(:notify)
    RelayDaemon::App.set(:push_notifier, notifier)

    post "/sessions/#{session["id"]}/test", "{}", auth_headers

    expect(last_response.status).to eq(200)
    expect(notifier).to have_received(:notify).with("tests_finished")
  end

  it "notifies when a configured test command completes" do
    repo = RelayDaemon::RepoStore.new(db).create(path: make_git_dir, test_command: "true")
    session = RelayDaemon::SessionStore.new(db).create(repo: repo, worktrees_dir: config.worktrees_dir)
    notifier = instance_double(RelayDaemon::PushNotifier)
    allow(notifier).to receive(:notify)
    RelayDaemon::App.set(:push_notifier, notifier)

    post "/sessions/#{session["id"]}/test", "{}", auth_headers

    expect(last_response.status).to eq(200)
    expect(notifier).to have_received(:notify).with("tests_finished")
  end

  it "emits tests_finished then agent_finished for an auto-retry run" do
    agent = File.expand_path("support/fake_session_agent.rb", __dir__)
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token,
      host: "127.0.0.1",
      port: 7777,
      db_path: db_path,
      worktrees_dir: config.worktrees_dir,
      agent_log_dir: config.agent_log_dir,
      agent_command: "ruby #{agent} {prompt}"
    ))
    repo = RelayDaemon::RepoStore.new(db).create(path: make_git_dir, test_command: "false")
    session_store = RelayDaemon::SessionStore.new(db)
    session = session_store.create(repo: repo, worktrees_dir: config.worktrees_dir)
    store.create(device_token: PUSH_DEVICE_TOKEN_ONE)
    http = RecordingPushHttp.new
    notifier = RelayDaemon::PushNotifier.new(
      relay_url: "https://push.example.test/push",
      relay_token: "relay-secret",
      environment: "production",
      device_store: store,
      http: http,
      logger: RecordingPushLogger.new
    )
    RelayDaemon::App.set(:push_notifier, notifier)

    post "/sessions/#{session["id"]}/test", { autoRetry: true }.to_json, auth_headers
    expect(last_response.status).to eq(200)

    message_store = RelayDaemon::MessageStore.new(db, session_store)
    deadline = Time.now + 3
    sleep 0.01 while message_store.list_for_session(session["id"]).length < 2 && Time.now < deadline
    expect(message_store.list_for_session(session["id"]).length).to eq(2)
    expect(notifier.wait_until_idle(timeout: 1.0)).to be true
    expect(http.requests.map { |request| JSON.parse(request[:body]).fetch("category") }).to eq([
      "tests_finished", "agent_finished"
    ])
  end
end
