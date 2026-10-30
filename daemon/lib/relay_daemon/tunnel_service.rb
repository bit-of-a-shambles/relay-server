# typed: false
# frozen_string_literal: true
require "json"
require "fileutils"
require "uri"
require "rack/mock"
require_relative "tunnel_crypto"
require_relative "tunnel_connection"

module RelayDaemon
  class TunnelService
    attr_reader :endpoint, :bus
    def initialize(endpoint:, path:, pairing:, bus:, app:, connector: nil, clock: -> { Time.now.to_i })
      uri = URI.parse(endpoint)
      raise ArgumentError, "cloud relay requires a WSS origin" unless uri.scheme == "wss" && uri.host && ["", "/"].include?(uri.path) && !uri.query && !uri.fragment && !uri.userinfo

      @endpoint, @path, @pairing, @bus, @app = endpoint.delete_suffix("/"), path, pairing, bus, app
      @clock, @mutex, @connections = clock, Mutex.new, {}
      @connector = connector || ->(room) { TunnelConnection.new(self, room).start }
      @rooms = File.exist?(path) ? JSON.parse(File.read(path)) : []
      raise ArgumentError, "invalid cloud pairing store" unless @rooms.is_a?(Array)

      prune
      @rooms.each { |room| @connections[room.fetch("room")] = @connector.call(room) }
    end

    def create(code)
      @mutex.synchronize do
        prune
        raise ArgumentError, "cloud device limit reached; revoke an old pairing first" if @rooms.length >= 16

        secret = SecureRandom.random_bytes(32)
        caps = TunnelCrypto.capabilities(secret)
        room = { "room" => caps.fetch("room"), "secret" => Base64.strict_encode64(secret), "code" => code, "expires" => @clock.call + 300 }
        @rooms << room
        persist
        @connections[room.fetch("room")] = @connector.call(room)
        { "url" => endpoint, "room" => room.fetch("room"), "phone" => caps.fetch("phone"), "secret" => room.fetch("secret") }
      end
    end

    def bind(code, token)
      @mutex.synchronize do
        room = @rooms.find { |item| item["code"] == code }
        return unless room

        room["tokenHash"] = Digest::SHA256.hexdigest(token)
        room.delete("code"); room.delete("expires")
        persist
      end
    end

    def authorized?(room, token)
      hash = room["tokenHash"]
      hash && hash == Digest::SHA256.hexdigest(token) && @pairing.token_valid?(token)
    end

    def dispatch(room, request)
      id = request.fetch("id")
      method, path, token, body = request.values_at("method", "path", "token", "body")
      raise ArgumentError, "invalid request" unless id.is_a?(String) && id.length <= 80 && %w[GET POST PUT PATCH DELETE].include?(method) && path.is_a?(String) && body.is_a?(String) && token.is_a?(String)

      uri = URI.parse(path)
      decoded_path = URI::DEFAULT_PARSER.unescape(uri.path)
      allowed_path = path.start_with?("/") && !path.start_with?("//") && !uri.host && !uri.fragment && !decoded_path.include?("..") && !decoded_path.include?("\\") && !decoded_path.start_with?("/internal", "/pair/start", "/ws")
      return response(id, 403, { error: "route unavailable through cloud relay" }.to_json) unless allowed_path
      claim = method == "POST" && decoded_path == "/pair/claim"
      return response(id, 403, { error: "route unavailable through cloud relay" }.to_json) if decoded_path.start_with?("/pair/") && !claim
      permitted = if claim
        room["expires"] && room["expires"] >= @clock.call && JSON.parse(body)["pairingCode"] == room["code"]
      else
        (decoded_path == "/healthz" && method == "GET") || authorized?(room, token)
      end
      return response(id, 401, { error: "unauthorized" }.to_json) unless permitted

      env = Rack::MockRequest.env_for(path, method: method, input: body, "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token}", "REMOTE_ADDR" => "127.0.0.1")
      status, _headers, stream = @app.call(env)
      text = +""
      begin
        stream.each do |part|
          text << part
          break if text.bytesize > 200_000
        end
      ensure
        stream.close if stream.respond_to?(:close)
      end
      return response(id, 413, { error: "response exceeds cloud transport limit" }.to_json) if text.bytesize > 200_000

      response(id, status, text)
    end

    def stop
      @connections.each_value(&:stop)
    end

    private

    def response(id, status, body)
      { "kind" => "response", "id" => id, "status" => status, "body" => body }
    end

    def prune
      @rooms.delete_if do |room|
        expired = (room["expires"] && room["expires"] < @clock.call) || (room["tokenHash"] && !@pairing.token_hash_valid?(room["tokenHash"]))
        # Claimed credentials remain durable, and every API/event checks the
        # underlying revocable daemon token. Pending rooms expire with the QR.
        @connections.delete(room["room"])&.stop if expired
        expired
      end
    end

    def persist
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      temp = @path + ".tmp"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(@rooms)) }
      File.rename(temp, @path)
    end
  end
end
