# typed: false
# frozen_string_literal: true

require "json"
require "rack/utils"
require "sorbet-runtime"
require "faye/websocket"
require_relative "event_bus"

module RelayDaemon
  # Wires a websocket connection to the EventBus.
  # Kept separate from the Rack middleware so it can be tested with a fake
  # websocket object (anything responding to send/close/on).
  module WsHandler
    # Close code for failed authentication (mirrors HTTP 401).
    UNAUTHORIZED = 4401

    # Attaches +ws+ to +bus+ when authorized; otherwise closes the socket
    # with code 4401 immediately. Token validation (static and paired
    # tokens) happens in the caller, which has access to app settings.
    def self.attach(ws, authorized:, bus:)
      unless authorized
        ws.close(UNAUTHORIZED)
        return
      end

      sub_id = bus.subscribe { |event| ws.send(JSON.generate(event)) }
      ws.on(:close) { bus.unsubscribe(sub_id) }
    end

    # True when +token+ matches the static daemon token or an unrevoked
    # paired token.
    def self.token_authorized?(token, static_token:, pairing:)
      static_ok = !static_token.nil? && !static_token.empty? &&
                  Rack::Utils.secure_compare(static_token, token)
      return true if static_ok

      !pairing.nil? && pairing.token_valid?(token)
    end
  end

  # Thin seam over Faye::WebSocket so the websocket path can be tested with
  # a fake upgrader injected via settings.
  module FayeUpgrader
    def self.upgrade?(env)
      Faye::WebSocket.websocket?(env)
    end

    def self.upgrade(env)
      Faye::WebSocket.new(env)
    end
  end

  # Rack middleware serving GET /ws. Runs before Sinatra so the hijacked
  # response ([-1, {}, []]) is passed to the server untouched — Sinatra's
  # response post-processing chokes on the -1 status.
  class WsRack
    def initialize(app, app_class)
      @app = app
      @app_class = app_class
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"] == "/ws"

      settings = @app_class.settings
      upgrader = settings.ws_upgrader
      unless upgrader.upgrade?(env)
        return [400, { "content-type" => "application/json" },
                [JSON.generate({ error: "websocket upgrade required" })]]
      end

      ws = upgrader.upgrade(env)
      authorized = WsHandler.token_authorized?(
        Rack::Request.new(env).params["token"].to_s,
        static_token: settings.relay_config.daemon_token,
        pairing: settings.pairing_service
      )
      WsHandler.attach(ws, authorized: authorized, bus: settings.event_bus)
      ws.rack_response
    end
  end
end
