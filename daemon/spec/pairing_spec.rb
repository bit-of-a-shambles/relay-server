# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/bind_safety"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/pairing_service"

RSpec.describe "Pairing API" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }
  let(:service) { RelayDaemon::PairingService.new(db) }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: nil, host: "127.0.0.1", port: 7777, db_path: db_path
    ))
    RelayDaemon::App.set(:pairing_service, service)
  end

  # Settings persist across spec files; reset so other specs are unaffected.
  after do
    RelayDaemon::App.set(:pairing_service, nil)
    db.connection.close
  end

  describe "POST /pair/start" do
    it "returns a qrPayload with url and a pairing code of 6+ chars" do
      post "/pair/start"
      expect(last_response.status).to eq(200)
      payload = JSON.parse(last_response.body)["qrPayload"]
      expect(payload["url"]).to eq("http://127.0.0.1:7777")
      expect(payload["pairingCode"].length).to be >= 6
    end

    it "accepts RFC1918 private requests" do
      post "/pair/start", "", { "REMOTE_ADDR" => "10.0.0.5" }
      expect(last_response.status).to eq(200)
    end

    it "accepts Tailscale-range requests" do
      post "/pair/start", "", { "REMOTE_ADDR" => "100.101.102.103" }
      expect(last_response.status).to eq(200)
    end

    it "rejects public requests with 403" do
      post "/pair/start", "", { "REMOTE_ADDR" => "8.8.8.8" }
      expect(last_response.status).to eq(403)
    end

    it "returns 503 when pairing is not configured" do
      RelayDaemon::App.set(:pairing_service, nil)
      # Keep auth from 500ing: provide a static token, /pair/* skips auth anyway
      post "/pair/start"
      expect(last_response.status).to eq(503)
    end
  end

  describe "POST /pair/claim" do
    def start_and_get_code
      post "/pair/start"
      JSON.parse(last_response.body)["qrPayload"]["pairingCode"]
    end

    def claim(code)
      post "/pair/claim", { pairingCode: code }.to_json,
           "CONTENT_TYPE" => "application/json"
    end

    it "exchanges a valid code for a 256-bit auth token, usable for auth" do
      code = start_and_get_code
      claim(code)
      expect(last_response.status).to eq(200)
      token = JSON.parse(last_response.body)["authToken"]
      expect(token).to match(/\A[0-9a-f]{64}\z/)

      get "/whoami", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
      expect(last_response.status).to eq(200)
    end

    it "rejects reuse of a claimed code with 401" do
      code = start_and_get_code
      claim(code)
      expect(last_response.status).to eq(200)
      claim(code)
      expect(last_response.status).to eq(401)
    end

    it "rejects an unknown code with 401" do
      claim("nope123")
      expect(last_response.status).to eq(401)
    end

    it "rejects an expired code with 401" do
      now = Time.now.utc
      clock_now = now
      ticking = RelayDaemon::PairingService.new(db, clock: -> { clock_now })
      RelayDaemon::App.set(:pairing_service, ticking)

      code = start_and_get_code
      clock_now = now + 301
      claim(code)
      expect(last_response.status).to eq(401)
    end

    it "rejects a missing pairingCode with 401" do
      post "/pair/claim", {}.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(401)
    end

    it "returns 400 on invalid JSON" do
      post "/pair/claim", "not json", "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(400)
    end

    it "returns 400 on non-object JSON" do
      post "/pair/claim", "[1]", "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(400)
    end

    it "returns 503 when pairing is not configured" do
      RelayDaemon::App.set(:pairing_service, nil)
      post "/pair/claim", { pairingCode: "x" }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(503)
    end
  end

  describe "auth integration" do
    it "rejects an invalid bearer when only pairing is configured" do
      get "/whoami", {}, { "HTTP_AUTHORIZATION" => "Bearer wrong" }
      expect(last_response.status).to eq(401)
    end

    it "accepts a paired token even when a static token is also set" do
      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: "static-secret", host: "127.0.0.1", port: 7777, db_path: db_path
      ))
      post "/pair/start"
      code = JSON.parse(last_response.body)["qrPayload"]["pairingCode"]
      post "/pair/claim", { pairingCode: code }.to_json, "CONTENT_TYPE" => "application/json"
      token = JSON.parse(last_response.body)["authToken"]

      get "/whoami", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
      expect(last_response.status).to eq(200)
    end

    it "rejects a revoked token" do
      post "/pair/start"
      code = JSON.parse(last_response.body)["qrPayload"]["pairingCode"]
      post "/pair/claim", { pairingCode: code }.to_json, "CONTENT_TYPE" => "application/json"
      token = JSON.parse(last_response.body)["authToken"]

      expect(service.revoke(token)).to eq(1)

      get "/whoami", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
      expect(last_response.status).to eq(401)
    end
  end
end

RSpec.describe RelayDaemon::PairingService do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }

  after { db.connection.close }

  subject(:service) { described_class.new(db) }

  describe "#revoke" do
    it "revokes by full token" do
      code = service.start_pairing
      token = service.claim(code)
      expect(service.revoke(token)).to eq(1)
      expect(service.token_valid?(token)).to be false
    end

    it "revokes by token-hash prefix" do
      code = service.start_pairing
      token = service.claim(code)
      hash = Digest::SHA256.hexdigest(token)
      expect(service.revoke(hash[0, 12])).to eq(1)
      expect(service.token_valid?(token)).to be false
    end

    it "returns 0 when nothing matches" do
      expect(service.revoke("ffffffffffff")).to eq(0)
    end

    it "does not double-revoke" do
      code = service.start_pairing
      token = service.claim(code)
      service.revoke(token)
      expect(service.revoke(token)).to eq(0)
    end
  end

  describe "#token_valid?" do
    it "returns false for an empty token" do
      expect(service.token_valid?("")).to be false
    end
  end
end

RSpec.describe RelayDaemon::BindSafety do
  it "accepts loopback, RFC1918, and Tailscale ranges" do
    %w[localhost 127.0.0.1 127.1.2.3 ::1 10.0.0.1 172.16.0.1 172.31.255.255
       192.168.1.1 100.64.0.1 100.127.255.255].each do |host|
      expect(described_class.safe?(host)).to be(true), "expected #{host} to be safe"
    end
  end

  it "rejects public and out-of-range addresses" do
    %w[0.0.0.0 8.8.8.8 172.32.0.1 100.128.0.1 2001:db8::1].each do |host|
      expect(described_class.safe?(host)).to be(false), "expected #{host} to be unsafe"
    end
  end

  it "rejects unparseable hosts" do
    expect(described_class.safe?("not-an-ip")).to be false
  end
end
