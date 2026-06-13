# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/bind_safety"

RSpec.describe RelayDaemon::BindSafety do
  describe ".bind_targets" do
    it "adds loopback alongside a distinct (e.g. Tailscale) host" do
      expect(described_class.bind_targets("100.66.1.2")).to eq(["100.66.1.2", "127.0.0.1"])
    end

    it "does not duplicate loopback when the host is already loopback" do
      expect(described_class.bind_targets("127.0.0.1")).to eq(["127.0.0.1"])
    end
  end

  describe ".loopback?" do
    it "returns true for 127.0.0.1" do
      expect(described_class.loopback?("127.0.0.1")).to be true
    end

    it "returns true for any 127.x.x.x address" do
      expect(described_class.loopback?("127.1.2.3")).to be true
    end

    it "returns true for IPv6 loopback ::1" do
      expect(described_class.loopback?("::1")).to be true
    end

    it "returns true for localhost" do
      expect(described_class.loopback?("localhost")).to be true
    end

    it "returns false for a Tailscale address" do
      expect(described_class.loopback?("100.64.0.1")).to be false
    end

    it "returns false for an RFC1918 address" do
      expect(described_class.loopback?("10.0.0.1")).to be false
    end

    it "returns false for an unparseable string" do
      expect(described_class.loopback?("not-an-ip")).to be false
    end
  end
end
