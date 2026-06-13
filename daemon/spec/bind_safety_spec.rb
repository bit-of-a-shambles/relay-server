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
end
