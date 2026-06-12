# typed: true
# frozen_string_literal: true

require "ipaddr"
require "sorbet-runtime"

module RelayDaemon
  # Guards the daemon against binding to publicly routable addresses.
  module BindSafety
    extend T::Sig

    SAFE_RANGES = T.let(
      [
        IPAddr.new("127.0.0.0/8"),     # loopback
        IPAddr.new("::1"),             # IPv6 loopback
        IPAddr.new("10.0.0.0/8"),      # RFC1918
        IPAddr.new("172.16.0.0/12"),   # RFC1918
        IPAddr.new("192.168.0.0/16"),  # RFC1918
        IPAddr.new("100.64.0.0/10")    # CGNAT / Tailscale
      ].freeze,
      T::Array[IPAddr]
    )

    # True when host is loopback, RFC1918 private, or Tailscale CGNAT.
    sig { params(host: String).returns(T::Boolean) }
    def self.safe?(host)
      return true if host == "localhost"

      ip = begin
        IPAddr.new(host)
      rescue IPAddr::Error
        return false
      end
      SAFE_RANGES.any? { |range| range.include?(ip) }
    end
  end
end
