# frozen_string_literal: true
require "spec_helper"
require "relay_daemon/tunnel_service"
require "relay_daemon/event_bus"
require "relay_daemon/pairing_service"

RSpec.describe RelayDaemon::TunnelService do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "cloud.json") }
  let(:db) { RelayDaemon::Db.new(File.join(dir, "db.sqlite3")) }
  let(:pairing) { RelayDaemon::PairingService.new(db) }
  let(:bus) { RelayDaemon::EventBus.new }
  let(:connections) { [] }
  let(:connector) { ->(room) { c = double(:connection, stop: nil); connections << c; c } }
  let(:rack_app) { ->(env) { [200, {}, [JSON.generate({ "path" => env["PATH_INFO"], "token" => env["HTTP_AUTHORIZATION"] })]] } }
  let(:now) { 1000 }
  let(:service) { described_class.new(endpoint: "wss://relay.test/", path: path, pairing: pairing, bus: bus, app: rack_app, connector: connector, clock: -> { now }) }
  after { db.connection.close }
  def room
    JSON.parse(File.read(path)).first
  end
  def rpc(**changes)
    { "kind" => "request", "id" => "request-1", "method" => "GET", "path" => "/repos", "token" => "", "body" => "" }.merge(changes.transform_keys(&:to_s))
  end
  def claim_room
    code = pairing.start_pairing
    service.create(code)
    token = pairing.claim(code)
    service.bind(code, token)
    [room, token]
  end
  it "creates private durable pairings with separate capabilities and resumes them" do
    config = service.create("one-code")
    expect(config["url"]).to eq("wss://relay.test")
    expect(config.keys).to contain_exactly("url", "room", "phone", "secret")
    expect(File.stat(path).mode & 0o077).to eq(0)
    expect(service.endpoint).to eq("wss://relay.test")
    expect(service.bus).to eq(bus)
    expect(service.authorized?(room, "bad")).to be_falsey
    service.bind("unknown", "token")
    described_class.new(endpoint: "wss://relay.test", path: path, pairing: pairing, bus: bus, app: rack_app, connector: connector)
    expect(connections.length).to eq(1) # expired unclaimed room was pruned on load
    service.stop
  end
  it "rejects malformed endpoints and corrupt stores" do
    ["https://relay.test", "wss://relay.test/path", "wss://user@relay.test", "wss://relay.test?q=x", "wss://relay.test#x"].each do |url|
      expect { described_class.new(endpoint: url, path: path, pairing: pairing, bus: bus, app: rack_app) }.to raise_error(ArgumentError)
    end
    File.write(path, "{}")
    expect { service }.to raise_error(ArgumentError)
  end
  it "binds single-use pairing, permits authorized requests, and enforces revocation" do
    record, token = claim_room
    expect(service.authorized?(record, token)).to be(true)
    expect(service.dispatch(record, rpc(token: token))["status"]).to eq(200)
    expect(service.dispatch(record, rpc(token: "other"))["status"]).to eq(401)
    pairing.revoke(token)
    expect(service.authorized?(record, token)).to be(false)
    service.create("new")
    expect(JSON.parse(File.read(path)).length).to eq(1)
    expect(connections.first).to have_received(:stop)
  end
  it "prunes expired QR rooms, reconnects claimed devices and caps device count" do
    record, = claim_room
    loaded = described_class.new(endpoint: "wss://relay.test", path: path, pairing: pairing, bus: bus, app: rack_app, connector: connector)
    expect(connections.length).to eq(2)
    expect(service.dispatch(record, rpc(path: "/healthz"))["status"]).to eq(200)
    service.create("old")
    service.instance_variable_set(:@clock, -> { 1400 })
    service.create("new")
    expect(JSON.parse(File.read(path)).length).to eq(2)
    14.times { |i| service.create("code-#{i}") }
    expect { service.create("overflow") }.to raise_error(ArgumentError, /limit/)
    loaded.stop
  end
  it "allows only its own unexpired encrypted claim and blocks private routes/SSRF" do
    service.create("correct")
    record = room
    request = rpc(method: "POST", path: "/pair/claim", body: '{"pairingCode":"correct"}')
    expect(service.dispatch(record, request)["status"]).to eq(200)
    expect(service.dispatch(record, request.merge("body" => '{"pairingCode":"wrong"}'))["status"]).to eq(401)
    service.instance_variable_set(:@clock, -> { 1400 })
    expect(service.dispatch(record, request)["status"]).to eq(401)
    ["/internal/calls", "/pair/start", "/pair/unknown", "/ws", "//evil.test/healthz", "https://evil.test/healthz", "/../internal/calls", "/%2e%2e/private", "/healthz#x", "/bad%5cpath"].each do |path|
      expect(service.dispatch(record, rpc(path: path))["status"]).to eq(403)
    end
    expect { service.dispatch(record, rpc(method: "TRACE")) }.to raise_error(ArgumentError)
    record, token = claim_room
    expect(service.dispatch(record, rpc(method: "PUT", token: token))["status"]).to eq(200)
    expect { service.dispatch(record, rpc(id: "a" * 81)) }.to raise_error(ArgumentError)
  end
  it "closes Rack bodies and returns a bounded error for oversized responses" do
    record, token = claim_room
    stream = double(:stream)
    allow(stream).to receive(:each).and_yield("x" * 200_001)
    allow(stream).to receive(:close)
    service.instance_variable_set(:@app, ->(_env) { [200, {}, stream] })
    expect(service.dispatch(record, rpc(token: token))["status"]).to eq(413)
    expect(stream).to have_received(:close)
  end
end

RSpec.describe RelayDaemon::TunnelConnection do
  class TunnelFakeReactor
    attr_reader :timers, :jobs, :cancelled
    def initialize; @timers = []; @jobs = []; @cancelled = []; end
    def schedule(&block); block.call; end
    def defer(work, callback); @jobs << [work, callback]; end
    def finish; work, callback = @jobs.shift; callback.call(work.call); end
    def add_timer(_delay, &block); @timers << block; @timers.length; end
    def cancel_timer(id); @cancelled << id; end
  end
  class TunnelFakeSocket
    attr_reader :events, :sent, :closed
    def initialize(*); @events = {}; @sent = []; @closed = []; end
    def on(name, &block); @events[name] = block; end
    def send(value); @sent << JSON.parse(value); end
    def close(*args)
      code = args.first || 1000
      raise ArgumentError, "Faye client requires 1000 or 3000..4999" unless code == 1000 || (3000..4999).cover?(code)

      @closed << args
    end
    def emit(type, value = nil); @events.fetch(type).call(value); end
  end
  let(:secret) { "\0" * 32 }
  let(:record) { { "secret" => Base64.strict_encode64(secret), "room" => "unused" } }
  let(:bus) { RelayDaemon::EventBus.new }
  let(:service) { double(:service, endpoint: "wss://relay.test", bus: bus, authorized?: true, dispatch: { "kind" => "response", "id" => "1", "status" => 200, "body" => "{}" }) }
  let(:reactor) { TunnelFakeReactor.new }
  let(:sockets) { [] }
  let(:factory) { list = sockets; Class.new { define_singleton_method(:new) { |*args, **opts| sock = TunnelFakeSocket.new; list << sock; sock } } }
  let(:connection) { described_class.new(service, record, reactor: reactor, sockets: factory) }
  before { allow(Faye::WebSocket).to receive(:ensure_reactor_running) }
  def socket; sockets.last; end
  def phone
    connection.start
    socket.emit(:open)
    connection.receive({ "type" => "peer.joined" })
    cipher = RelayDaemon::TunnelCrypto.new(secret, role: "phone")
    connection.receive(cipher.hello)
    cipher.accept_hello(socket.sent.last)
    cipher
  end
  it "runs encrypted RPC/events and cleans up subscriptions/reconnects" do
    cipher = phone
    connection.receive(cipher.seal({ "kind" => "request", "id" => "1" }))
    reactor.finish
    expect(cipher.open(socket.sent.last)["status"]).to eq(200)
    connection.receive(cipher.seal({ "kind" => "subscribe", "token" => "token" }))
    expect(cipher.open(socket.sent.last).dig("event", "type")).to eq("connection.ready")
    connection.receive(cipher.seal({ "kind" => "subscribe", "token" => "token" }))
    cipher.open(socket.sent.last)
    bus.publish(type: "message.updated")
    expect(cipher.open(socket.sent.last).dig("event", "type")).to eq("message.updated")
    connection.receive(cipher.seal({ "kind" => "unsubscribe" }))
    connection.receive(cipher.seal({ "kind" => "subscribe", "token" => "token" }))
    cipher.open(socket.sent.last)
    allow(service).to receive(:authorized?).and_return(false)
    bus.publish(type: "message.updated")
    expect(socket.closed.last).to eq([4001, "pairing revoked"])
    socket.emit(:close)
    expect(reactor.timers).to be_empty
    socket.emit(:error)
    connection.stop
    socket.emit(:close)
    connection.connect
  end
  it "rejects bad frames, unauthorized events, overload and ignores stale replies" do
    cipher = phone
    socket.emit(:message, Struct.new(:data).new("bad-json"))
    expect(socket.closed.last.first).to eq(4003)
    expect { connection.receive({ "type" => "bad" }) }.to raise_error(ArgumentError)
    expect { connection.receive(cipher.seal({ "kind" => "bad" })) }.to raise_error(ArgumentError)
    allow(service).to receive(:authorized?).and_return(false)
    expect { connection.receive(cipher.seal({ "kind" => "subscribe", "token" => "token" })) }.to raise_error(ArgumentError)
    connection.instance_variable_set(:@inflight, 32)
    expect { connection.receive(cipher.seal({ "kind" => "request" })) }.to raise_error(ArgumentError)
    connection.instance_variable_set(:@inflight, 0)
    allow(service).to receive(:dispatch).and_raise(ArgumentError)
    connection.receive(cipher.seal({ "kind" => "request", "id" => "bad" }))
    reactor.finish
    expect(cipher.open(socket.sent.last)["status"]).to eq(400)
    connection.receive(cipher.seal({ "kind" => "request", "id" => "old" }))
    connection.receive({ "type" => "peer.left" })
    reactor.finish
    fresh = RelayDaemon::TunnelCrypto.new(secret, role: "phone")
    connection.receive(fresh.hello)
    fresh.accept_hello(socket.sent.last)
    socket.emit(:message, Struct.new(:data).new(JSON.generate(fresh.seal({ "kind" => "request" }))))
    reactor.finish
    expect(fresh.open(socket.sent.last)["status"]).to eq(400)
    connection.stop
  end
  it "expires unclaimed sockets, preserves claimed ones and ignores old socket callbacks" do
    record["expires"] = Time.now.to_i + 300
    connection.start
    old = socket
    expiry = reactor.timers.last
    record.delete("expires")
    expiry.call
    expect(old.closed).to be_empty
    old.emit(:close)
    expect(reactor.cancelled).to include(1)
    reactor.timers.last.call
    old.emit(:open)
    old.emit(:message, Struct.new(:data).new("bad-json"))
    old.emit(:close)
    expect(sockets.length).to eq(2)
    record["expires"] = Time.now.to_i + 300
    socket.emit(:close)
    reactor.timers.last.call
    reactor.timers.last.call
    expect(socket.closed).not_to be_empty
    connection.stop
  end
  it "ignores an event queued by a disconnected session" do
    cipher = phone
    connection.receive(cipher.seal({ "kind" => "subscribe", "token" => "token" }))
    queued = []
    allow(reactor).to receive(:schedule) { |&block| queued << block }
    bus.publish(type: "message.updated")
    connection.receive({ "type" => "peer.left" })
    count = socket.sent.length
    queued.each(&:call)
    expect(socket.sent.length).to eq(count)
    allow(reactor).to receive(:schedule).and_call_original
    connection.stop
  end
  it "closes oversized event streams without crashing the reactor" do
    cipher = phone
    connection.receive(cipher.seal({ "kind" => "subscribe", "token" => "token" }))
    bus.publish(type: "message.updated", payload: { content: "x" * 524_289 })
    expect(socket.closed.last).to eq([4002, "encrypted message unavailable"])
    connection.stop
  end
  it "can accept a first hello without a separate peer notification" do
    connection.start
    cipher = RelayDaemon::TunnelCrypto.new(secret, role: "phone")
    connection.receive(cipher.hello)
    cipher.accept_hello(socket.sent.last)
    connection.stop
  end
end

require "relay_daemon/app"
RSpec.describe "Cloud pairing API" do
  include Rack::Test::Methods
  def app; RelayDaemon::App; end
  let(:dir) { Dir.mktmpdir }
  let(:db) { RelayDaemon::Db.new(File.join(dir, "cloud.sqlite3")) }
  let(:pairing) { RelayDaemon::PairingService.new(db) }
  let(:tunnel) { double(:tunnel, create: { "url" => "wss://relay.test" }, bind: nil) }
  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(daemon_token: nil, host: "127.0.0.1", port: 17777, db_path: File.join(dir, "cloud.sqlite3")))
    RelayDaemon::App.set(:pairing_service, pairing)
    RelayDaemon::App.set(:tunnel_service, tunnel)
  end
  after do
    RelayDaemon::App.set(:tunnel_service, nil)
    RelayDaemon::App.set(:pairing_service, nil)
    db.connection.close
  end
  it "supports cloud-only pairing while bound safely to loopback" do
    post "/pair/start"
    expect(last_response.status).to eq(200)
    value = JSON.parse(last_response.body).fetch("qrPayload")
    expect(value.dig("relay", "url")).to eq("wss://relay.test")
    post "/pair/claim", { pairingCode: value["pairingCode"] }.to_json, "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
    expect(tunnel).to have_received(:bind).with(value["pairingCode"], JSON.parse(last_response.body)["authToken"])
  end
  it "pairs and serves the real authenticated Rack API entirely through ciphertext" do
    reactor = TunnelFakeReactor.new
    sockets = []
    factory = Class.new do
      define_singleton_method(:new) do |*args, **opts|
        socket = TunnelFakeSocket.new
        sockets << socket
        socket
      end
    end
    bus = RelayDaemon::EventBus.new
    relay = RelayDaemon::TunnelService.new(endpoint: "wss://relay.test", path: File.join(dir, "cloud.json"),
      pairing: pairing, bus: bus, app: RelayDaemon::App, connector: ->(_room) { double(stop: nil) })
    RelayDaemon::App.set(:tunnel_service, relay)
    code = pairing.start_pairing
    qr = relay.create(code)
    record = relay.instance_variable_get(:@rooms).first
    connection = RelayDaemon::TunnelConnection.new(relay, record, reactor: reactor, sockets: factory).start
    phone = RelayDaemon::TunnelCrypto.new(Base64.strict_decode64(qr.fetch("secret")), role: "phone")
    connection.receive(phone.hello)
    phone.accept_hello(sockets.last.sent.last)
    connection.receive(phone.seal({ "kind" => "request", "id" => "claim", "method" => "POST", "path" => "/pair/claim", "token" => "", "body" => { pairingCode: code }.to_json }))
    reactor.finish
    claimed = phone.open(sockets.last.sent.last)
    expect(claimed["status"]).to eq(200)
    token = JSON.parse(claimed["body"]).fetch("authToken")
    connection.receive(phone.seal({ "kind" => "request", "id" => "who", "method" => "GET", "path" => "/whoami", "token" => token, "body" => "" }))
    reactor.finish
    expect(JSON.parse(phone.open(sockets.last.sent.last)["body"])).to eq({ "ok" => true })
    connection.receive(phone.seal({ "kind" => "subscribe", "token" => token }))
    phone.open(sockets.last.sent.last)
    bus.publish(type: "message.updated", payload: { content: "private_repository_code" })
    expect(phone.open(sockets.last.sent.last).dig("event", "payload", "content")).to eq("private_repository_code")
    wire = JSON.generate(sockets.last.sent)
    [qr.fetch("secret"), code, token, "private_repository_code", "/whoami"].each { |marker| expect(wire).not_to include(marker) }
    pairing.revoke(token)
    bus.publish(type: "message.updated")
    expect(sockets.last.closed.last).to eq([4001, "pairing revoked"])
    connection.stop
    relay.stop
  end
  it "fails closed when cloud room creation fails" do
    allow(tunnel).to receive(:create).and_raise(IOError)
    post "/pair/start"
    expect(last_response.status).to eq(503)
  end
  it "reads explicit self-host settings without changing existing defaults" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("RELAY_TUNNEL_URL", anything).and_return("wss://relay.test")
    allow(ENV).to receive(:fetch).with("RELAY_TUNNEL_STORE", anything).and_return("/tmp/cloud-pairings.json")
    config = RelayDaemon::Config.from_env
    expect(config.tunnel_url).to eq("wss://relay.test")
    expect(config.tunnel_store_path).to eq("/tmp/cloud-pairings.json")
  end
end
