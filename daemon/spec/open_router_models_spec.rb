# frozen_string_literal: true
require "spec_helper"
require "relay_daemon/open_router_models"

RSpec.describe RelayDaemon::OpenRouterModels do
  it "loads all pages, sorts and deduplicates exact IDs, and caches for an hour" do
    now = 0.0
    offsets = []
    transport = lambda do |offset|
      offsets << offset
      if offset.zero?
        { data: [{ id: "z/model:free" }, { id: "a/model" }], links: { next: "next" } }.to_json
      else
        { data: [{ id: "a/model" }, { id: "b/model" }], links: { next: nil } }.to_json
      end
    end
    catalog = described_class.new(transport: transport, clock: -> { now })
    result = catalog.catalog
    expect(result).to eq("openRouter" => %w[a/model b/model z/model:free], "openRouterStatus" => "live")
    expect(offsets).to eq([0, 2])
    result["openRouter"].clear
    expect(catalog.catalog["openRouter"]).to eq(%w[a/model b/model z/model:free])
    now = 3601.0
    expect(catalog.catalog["openRouterStatus"]).to eq("live")
    expect(offsets).to eq([0, 2, 0, 2])
  end

  it "retains the last complete catalog on failure and retries after a minute" do
    now = 0.0
    transport = ->(_offset) { { data: [{ id: "vendor/model" }] }.to_json }
    catalog = described_class.new(transport: transport, clock: -> { now })
    expect(catalog.catalog["openRouterStatus"]).to eq("live")
    catalog.instance_variable_set(:@transport, ->(_offset) { raise Timeout::Error })
    now = 3601.0
    expect(catalog.catalog).to eq("openRouter" => ["vendor/model"], "openRouterStatus" => "cached")
    catalog.instance_variable_set(:@transport, transport)
    expect(catalog.catalog["openRouterStatus"]).to eq("cached")
    now = 3662.0
    expect(catalog.catalog["openRouterStatus"]).to eq("live")
  end

  it "rejects malformed responses and never publishes a partial catalog" do
    ["invalid JSON", "[]", '{"data":null}', '{"data":[]}', '{"data":[null]}', '{"data":[{"id":2}]}', '{"data":[{"id":" "}]}'].each do |body|
      catalog = described_class.new(transport: ->(_offset) { body })
      expect(catalog.catalog).to eq("openRouter" => [], "openRouterStatus" => "unavailable")
    end
    catalog = described_class.new(transport: lambda do |offset|
      offset.zero? ? '{"data":[{"id":"vendor/model"}],"links":{"next":"next"}}' : '{"data":[]}'
    end)
    expect(catalog.catalog["openRouter"]).to eq([])
  end

  it "requests only public model metadata with bounded timeouts" do
    http = instance_double(Net::HTTP)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    allow(response).to receive(:body).and_return('{"data":[{"id":"vendor/model"}]}')
    expect(Net::HTTP).to receive(:start).with("openrouter.ai", 443, use_ssl: true, open_timeout: 5, read_timeout: 10).and_yield(http)
    expect(http).to receive(:request) do |request|
      expect(request.path).to eq("/api/v1/models?offset=0")
      expect(request["Authorization"]).to be_nil
      response
    end
    expect(described_class.new.catalog["openRouter"]).to eq(["vendor/model"])
  end

  it "falls back when OpenRouter returns an HTTP error" do
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_return(Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable"))
    expect(described_class.new.catalog["openRouterStatus"]).to eq("unavailable")
  end

  it "keeps the endpoint available during DNS and TLS failures" do
    [SocketError, OpenSSL::SSL::SSLError].each do |error|
      catalog = described_class.new(transport: ->(_offset) { raise error, "unavailable" })
      expect(catalog.catalog["openRouterStatus"]).to eq("unavailable")
    end
  end
end
