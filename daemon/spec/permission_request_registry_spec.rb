# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/permission_request_registry"
require "timeout"

RSpec.describe RelayDaemon::PermissionRequestRegistry do
  let(:registry) { described_class.new }

  it "returns the client's decision when resolved before the timeout" do
    result = nil
    thread = Thread.new { result = registry.await("req-1", timeout_seconds: 2) }
    Timeout.timeout(1) { Thread.pass until thread.status == "sleep" }

    expect(registry.resolve("req-1", "allow")).to be true
    thread.join
    expect(result).to eq("allow")
  end

  it "denies after the timeout elapses with no resolution" do
    expect(registry.await("req-2", timeout_seconds: 0.05)).to eq("deny")
  end

  it "returns false when resolving an unknown or already-finished request" do
    expect(registry.resolve("missing", "allow")).to be false
  end

  it "forgets a request once it resolves, so a late duplicate resolve is a no-op" do
    thread = Thread.new { registry.await("req-3", timeout_seconds: 2) }
    Timeout.timeout(1) { Thread.pass until thread.status == "sleep" }

    expect(registry.resolve("req-3", "deny")).to be true
    thread.join
    expect(registry.resolve("req-3", "allow")).to be false
  end
end
