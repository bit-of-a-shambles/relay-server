# typed: false
# frozen_string_literal: true
require "faye/websocket"
require_relative "tunnel_crypto"

module RelayDaemon
  class TunnelConnection
    def initialize(service, room, reactor: EventMachine, sockets: Faye::WebSocket::Client)
      @service, @room, @reactor, @sockets = service, room, reactor, sockets
      @secret = Base64.strict_decode64(room.fetch("secret"))
      @stopped, @inflight, @backoff = false, 0, 1
    end

    def start
      Faye::WebSocket.ensure_reactor_running
      @reactor.schedule { connect }
      self
    end

    def stop(code = 1000, reason = "closed")
      @stopped = true
      @reactor.schedule do
        @reactor.cancel_timer(@timer) if @timer
        @reactor.cancel_timer(@expiry) if @expiry
        cleanup
        @socket&.close(code, reason)
      end
    end

    def connect
      return if @stopped

      caps = TunnelCrypto.capabilities(@secret)
      url = "#{@service.endpoint}/v1/rooms/#{caps.fetch('room')}/host"
      socket = @sockets.new(url, nil, headers: { "Authorization" => "Bearer #{caps.fetch('host')}", "X-Relay-Phone-Hash" => Digest::SHA256.hexdigest(caps.fetch("phone")) }, ping: 30, max_length: 710_000)
      @socket = socket
      if @room["expires"]
        @expiry = @reactor.add_timer([@room["expires"] - Time.now.to_i, 0].max) { stop if @room["expires"] }
      end
      socket.on(:open) { @backoff = 1 if @socket.equal?(socket) }
      socket.on(:message) do |event|
        next unless @socket.equal?(socket)

        begin
          receive(JSON.parse(event.data))
        rescue StandardError
          socket.close(4003, "invalid encrypted session")
        end
      end
      socket.on(:error) { socket.close }
      socket.on(:close) do
        next unless @socket.equal?(socket)

        @socket = nil
        @reactor.cancel_timer(@expiry) if @expiry
        cleanup
        unless @stopped
          @timer = @reactor.add_timer(@backoff) { connect }
          @backoff = [@backoff * 2, 30].min
        end
      end
    end

    def receive(frame)
      case frame["type"]
      when "peer.joined", "peer.left"
        cleanup
        @crypto = TunnelCrypto.new(@secret)
      when "hello"
        @crypto ||= TunnelCrypto.new(@secret)
        @socket.send(JSON.generate(@crypto.accept_hello(frame)))
      when "data"
        value = @crypto.open(frame)
        if value["kind"] == "subscribe"
          subscribe(value.fetch("token"))
        elsif value["kind"] == "unsubscribe"
          @service.bus.unsubscribe(@subscription) if @subscription
          @subscription = nil
        elsif value["kind"] == "request"
          raise ArgumentError, "too many pending requests" if @inflight >= 32

          @inflight += 1
          session = @crypto
          @reactor.defer(
            -> { @service.dispatch(@room, value) rescue { "kind" => "response", "id" => value["id"], "status" => 400, "body" => '{"error":"invalid cloud request"}' } },
            lambda { |response|
              @inflight -= 1
              send_encrypted(response) if @crypto.equal?(session)
            }
          )
        else
          raise ArgumentError, "unknown encrypted message"
        end
      else
        raise ArgumentError, "unknown wire message"
      end
    end

    private

    def subscribe(token)
      raise ArgumentError, "unauthorized subscription" unless @service.authorized?(@room, token)

      @service.bus.unsubscribe(@subscription) if @subscription
      session = @crypto
      @subscription = @service.bus.subscribe do |event|
        @reactor.schedule do
          next unless @crypto.equal?(session)

          if @service.authorized?(@room, token)
            send_encrypted({ "kind" => "event", "event" => event })
          else
            stop(4001, "pairing revoked")
          end
        end
      end
      send_encrypted({ "kind" => "event", "event" => { "type" => "connection.ready", "payload" => {} } })
    end

    def send_encrypted(value)
      @socket.send(JSON.generate(@crypto.seal(value)))
    rescue StandardError
      cleanup
      @socket&.close(4002, "encrypted message unavailable")
    end

    def cleanup
      @service.bus.unsubscribe(@subscription) if @subscription
      @subscription = nil
      @crypto = nil
    end
  end
end
