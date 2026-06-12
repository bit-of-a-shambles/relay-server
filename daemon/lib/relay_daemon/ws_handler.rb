# typed: false
# frozen_string_literal: true

require "json"
require "rack/utils"
require "sorbet-runtime"
require "faye/websocket"
require_relative "event_bus"

module RelayDaemon
  # Wires a websocket connection to the EventBus.
  # Kept separate from the Sinatra route so it can be tested with a fake
  # websocket object (anything responding to send/close/on).
  module WsHandler
    # Close code for failed authentication (mirrors HTTP 401).
    UNAUTHORIZED = 4401

    # Attaches +ws+ to +bus+ when +token+ matches +expected_token+;
    # otherwise closes the socket with code 4401 immediately.
    def self.attach(ws, token:, expected_token:, bus:)
      unless expected_token && !expected_token.empty? &&
             Rack::Utils.secure_compare(expected_token, token.to_s)
        ws.close(UNAUTHORIZED)
        return
      end

      sub_id = bus.subscribe { |event| ws.send(JSON.generate(event)) }
      ws.on(:close) { bus.unsubscribe(sub_id) }
    end
  end

  # Thin seam over Faye::WebSocket so the Sinatra route can be tested with
  # a fake upgrader injected via settings.
  module FayeUpgrader
    def self.upgrade?(env)
      Faye::WebSocket.websocket?(env)
    end

    def self.upgrade(env)
      Faye::WebSocket.new(env)
    end
  end
end
