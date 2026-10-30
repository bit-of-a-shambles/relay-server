# typed: false
# frozen_string_literal: true

require "openssl"
require "base64"
require "json"
require "securerandom"

module RelayDaemon
  # PSK-authenticated ephemeral ECDH. Only the two QR-paired devices have the
  # 256-bit PSK. Fresh ephemeral keys on every connection provide forward secrecy.
  class TunnelCrypto
    LABEL = "relay-tunnel-v1/"
    MAX_BYTES = 524_288

    def self.derive(secret, label)
      OpenSSL::KDF.hkdf(secret, salt: "", info: LABEL + label, length: 32, hash: "SHA256")
    end

    def self.capabilities(secret)
      host = derive(secret, "host").unpack1("H*")
      phone = derive(secret, "phone").unpack1("H*")
      { "room" => OpenSSL::Digest::SHA256.hexdigest(host), "host" => host, "phone" => phone }
    end

    def initialize(secret, role: "host", key: nil, nonce: nil)
      raise ArgumentError, "invalid tunnel secret or role" unless secret.bytesize == 32 && %w[host phone].include?(role)

      @secret, @role = secret, role
      @key = key || OpenSSL::PKey::EC.generate("prime256v1")
      @public = @key.public_key.to_octet_string(:uncompressed)
      @nonce = nonce || SecureRandom.random_bytes(32)
      @sent = @received = 0
    end

    def hello
      raise ArgumentError, "only the phone initiates" unless @role == "phone"

      hello_frame(proof("phone", @public + @nonce))
    end

    def accept_hello(frame)
      raise ArgumentError, "handshake already complete" if @send_key

      public_bytes = Base64.strict_decode64(frame.fetch("public"))
      nonce = Base64.strict_decode64(frame.fetch("nonce"))
      signature = Base64.strict_decode64(frame.fetch("proof"))
      raise ArgumentError, "invalid handshake" unless frame["type"] == "hello" && public_bytes.bytesize == 65 && nonce.bytesize == 32

      phone = @role == "host" ? public_bytes + nonce : @public + @nonce
      host = @role == "host" ? @public + @nonce : public_bytes + nonce
      expected = @role == "host" ? proof("phone", phone) : proof("host", phone + host)
      raise ArgumentError, "untrusted tunnel peer" unless signature.bytesize == 32 && OpenSSL.fixed_length_secure_compare(signature, expected)

      algorithm = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId("id-ecPublicKey"), OpenSSL::ASN1::ObjectId("prime256v1")])
      peer = OpenSSL::PKey.read(OpenSSL::ASN1::Sequence([algorithm, OpenSSL::ASN1::BitString(public_bytes)]).to_der)
      shared = @key.derive(peer)
      transcript = OpenSSL::Digest::SHA256.digest(phone + host)
      @send_key = session_key(shared, @role, transcript)
      @receive_key = session_key(shared, @role == "host" ? "phone" : "host", transcript)
      @role == "host" ? hello_frame(proof("host", phone + host)) : nil
    end

    def seal(value)
      raise ArgumentError, "handshake required" unless @send_key

      plain = JSON.generate(value)
      raise ArgumentError, "tunnel payload too large" if plain.bytesize > MAX_BYTES
      raise ArgumentError, "tunnel counter exhausted" if @sent >= (2**53 - 1)

      cipher = OpenSSL::Cipher.new("chacha20-poly1305").encrypt
      cipher.key = @send_key
      cipher.iv = nonce_for(@sent)
      cipher.auth_data = LABEL + @role + "/" + @sent.to_s
      encrypted = cipher.update(plain) + cipher.final + cipher.auth_tag
      frame = { "type" => "data", "n" => @sent, "c" => Base64.strict_encode64(encrypted) }
      @sent += 1
      frame
    end

    def open(frame)
      raise ArgumentError, "invalid tunnel sequence" unless @receive_key && frame["type"] == "data" && frame["n"] == @received

      encrypted = Base64.strict_decode64(frame.fetch("c"))
      raise ArgumentError, "invalid tunnel payload size" unless encrypted.bytesize.between?(17, MAX_BYTES + 16)

      cipher = OpenSSL::Cipher.new("chacha20-poly1305").decrypt
      cipher.key = @receive_key
      cipher.iv = nonce_for(@received)
      cipher.auth_tag = encrypted[-16, 16]
      cipher.auth_data = LABEL + (@role == "host" ? "phone" : "host") + "/" + @received.to_s
      result = JSON.parse(cipher.update(encrypted[0...-16]) + cipher.final)
      @received += 1
      result
    end

    private

    def nonce_for(counter)
      "\0" * 4 + [counter].pack("Q>")
    end

    def proof(role, bytes)
      OpenSSL::HMAC.digest("SHA256", @secret, LABEL + role + "/" + bytes)
    end

    def session_key(shared, role, transcript)
      OpenSSL::KDF.hkdf(shared, salt: @secret, info: LABEL + role + "/" + transcript, length: 32, hash: "SHA256")
    end

    def hello_frame(signature)
      { "type" => "hello", "public" => Base64.strict_encode64(@public), "nonce" => Base64.strict_encode64(@nonce), "proof" => Base64.strict_encode64(signature) }
    end
  end
end
