# frozen_string_literal: true
require "spec_helper"
require "relay_daemon/tunnel_crypto"
RSpec.describe RelayDaemon::TunnelCrypto do
  let(:secret) { "\0" * 32 }
  def peers(secret)
    host = described_class.new(secret)
    phone = described_class.new(secret, role: "phone")
    phone.accept_hello(host.accept_hello(phone.hello))
    [host, phone]
  end
  it "derives separate routing capabilities without exposing the bootstrap key" do
    caps = described_class.capabilities(secret)
    expect(caps.values.uniq.length).to eq(3)
    expect(caps["room"]).to eq(OpenSSL::Digest::SHA256.hexdigest(caps["host"]))
  end
  it "authenticates both directions, hides content and rejects replay" do
    host, phone = peers(secret)
    value = { "kind" => "request", "token" => "private_daemon_token", "content" => "private_code_marker" }
    frame = phone.seal(value)
    expect(JSON.generate(frame)).not_to include("private_daemon_token", "private_code_marker")
    expect(host.open(frame)).to eq(value)
    expect(phone.open(host.seal({ "answer" => "ok" }))).to eq({ "answer" => "ok" })
    expect { host.open(frame) }.to raise_error(ArgumentError)
  end
  it "rejects invalid secrets, roles, handshakes and unauthenticated peers" do
    expect { described_class.new("short") }.to raise_error(ArgumentError)
    expect { described_class.new(secret, role: "other") }.to raise_error(ArgumentError)
    host = described_class.new(secret)
    expect { host.hello }.to raise_error(ArgumentError)
    phone = described_class.new(secret, role: "phone")
    expect { host.accept_hello(phone.hello.merge("nonce" => "AA==")) }.to raise_error(ArgumentError)
    expect { host.accept_hello(phone.hello.merge("type" => "data")) }.to raise_error(ArgumentError)
    expect { host.accept_hello(phone.hello.merge("proof" => "AA==")) }.to raise_error(ArgumentError)
    expect { host.accept_hello(described_class.new("x" * 32, role: "phone").hello) }.to raise_error(ArgumentError)
    expect { host.seal({}) }.to raise_error(ArgumentError)
    expect { host.open({}) }.to raise_error(ArgumentError)
    phone.accept_hello(host.accept_hello(phone.hello))
    expect { host.accept_hello(phone.hello) }.to raise_error(ArgumentError)
  end
  it "rejects tampering, oversized payloads and exhausted counters" do
    host, phone = peers(secret)
    frame = phone.seal({ "private" => "code" })
    wrong = Base64.strict_decode64(frame["c"]); wrong.setbyte(0, wrong.getbyte(0) ^ 1)
    expect { host.open(frame.merge("c" => Base64.strict_encode64(wrong))) }.to raise_error(OpenSSL::Cipher::CipherError)
    expect { host.open(frame.merge("c" => "AA==")) }.to raise_error(ArgumentError)
    expect { host.seal({ "large" => "a" * described_class::MAX_BYTES }) }.to raise_error(ArgumentError)
    host.instance_variable_set(:@sent, 2**53 - 1)
    expect { host.seal({}) }.to raise_error(ArgumentError)
    expect(host.open(frame)).to eq({ "private" => "code" })
  end
  it "cannot decrypt prior ciphertext with a new ephemeral connection" do
    _, phone = peers(secret)
    old = phone.seal({ "old" => true })
    new_host, = peers(secret)
    expect { new_host.open(old) }.to raise_error(OpenSSL::Cipher::CipherError)
  end
end
