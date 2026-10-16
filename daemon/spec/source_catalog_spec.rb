# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"

RSpec.describe RelayDaemon::SourceCatalog do
  let(:db) { RelayDaemon::Db.new(File.join(Dir.mktmpdir, "sources.sqlite3")) }
  let(:store) { RelayDaemon::ProviderStore.new(db) }
  let(:open_router) { RelayDaemon::OpenRouterModels.new(transport: ->(_offset) { '{"data":[{"id":"cloud/model"}]}' }) }
  let(:env) { { "OPENROUTER_API_KEY" => "router-secret", "DOUBLEWORD_API_KEY" => "dw-secret" } }
  let(:requests) { [] }
  let(:transport) { ->(url, key) { requests << [url, key]; { status: 200, body: '{"data":[{"id":"coder"},{"id":"coder"}]}' } } }
  after { db.close_current_connection }

  it "discovers presets and manual endpoints, redacts credentials, caches and refreshes" do
    store.create(name: "manual", base_url: "http://localhost:8000/v1", api_key: "manual-secret")
    catalog = described_class.new(store: store, open_router: open_router, env: env, transport: transport)
    first = catalog.catalog
    expect(first.map { |source| source["providerId"] }).to eq(%w[openrouter manual ollama lmstudio doubleword])
    expect(first.last).to include("models" => ["coder"], "status" => "ready", "inferenceModes" => %w[realtime async])
    expect(first[2]["kind"]).to eq("local")
    expect(first.to_json).not_to include("secret")
    expect(requests.length).to eq(4)
    catalog.catalog
    expect(requests.length).to eq(4)
    catalog.catalog(refresh: true)
    expect(requests.length).to eq(8)
    expect(catalog.routing_providers["doubleword"]).to eq("baseUrl" => "https://api.doubleword.ai/v1", "apiKey" => "dw-secret")
    expect(catalog.routing_providers["ollama"]).not_to have_key("apiKey")
    config = RelayDaemon::RoutingConfigWriter.new(RelayDaemon::EvalStore.new(db), source_catalog: catalog).config
    expect(config["providers"]).to eq(catalog.routing_providers)
  end

  it "uses configured preset endpoints and keys instead of environment defaults" do
    store.create(name: "doubleword", base_url: "https://dedicated.example/v1", api_key: "stored-key")
    catalog = described_class.new(store: store, open_router: open_router, env: env, transport: transport)
    expect(catalog.catalog.count { |source| source["providerId"] == "doubleword" }).to eq(1)
    expect(requests).to include(["https://dedicated.example/v1", "stored-key"])
  end

  it "reports missing credentials and denied authentication without leaking error bodies" do
    catalog = described_class.new(store: store, open_router: open_router, env: {}, transport: ->(_url, _key) { { status: 401, body: "secret" } })
    sources = catalog.catalog
    expect(sources.map { |source| source["status"] }.uniq).to eq(["auth_required"])
    expect(sources.to_json).not_to include("secret")
  end

  it "retains successful model lists when refresh fails and invalidates them when credentials change" do
    now = 0.0
    response = { status: 200, body: '{"data":[{"id":"local-coder"}]}' }
    catalog = described_class.new(store: store, open_router: open_router, env: env, clock: -> { now }, transport: ->(_url, _key) { response })
    expect(catalog.catalog[1]["status"]).to eq("ready")
    now = 61.0
    response = { status: 500, body: "private server error" }
    expect(catalog.catalog[1]).to include("status" => "cached", "models" => ["local-coder"])
    store.create(name: "ollama", base_url: "http://localhost:9999/v1", api_key: "changed")
    expect(catalog.catalog.find { |source| source["providerId"] == "ollama" }).to include("status" => "unavailable", "models" => [])
  end

  it "handles invalid and unreachable endpoints, retaining declared manual model IDs" do
    store.create(name: "manual", base_url: "http://localhost:8000/v1", models: ["declared"])
    ['{', '{}', '{"data":false}', '{"data":[{}]}'].each do |body|
      catalog = described_class.new(store: store, open_router: open_router, env: env, transport: ->(_url, _key) { { status: 200, body: body } })
      expect(catalog.catalog[1]).to include("models" => ["declared"], "status" => "cached")
    end
    catalog = described_class.new(store: store, open_router: open_router, env: env, transport: ->(_url, _key) { raise IOError, "offline" })
    expect(catalog.catalog.last["status"]).to eq("unavailable")
  end

  it "uses bounded HTTP requests and sends keys only to the configured endpoint" do
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request) do |request|
      expect(request.path).to eq("/v1/models")
      expect(request["Authorization"]).to eq("Bearer dw-secret") if request.uri.host == "api.doubleword.ai"
      double(code: "200", body: '{"data":[{"id":"model"}]}')
    end
    allow(Net::HTTP).to receive(:start).with(anything, anything, use_ssl: anything, open_timeout: 3, read_timeout: 5).and_yield(http)
    catalog = described_class.new(store: store, open_router: open_router, env: env)
    expect(catalog.catalog.last["models"]).to eq(["model"])
  end
end

RSpec.describe "Model sources API" do
  include Rack::Test::Methods
  def app = RelayDaemon::App
  let(:catalog) { instance_double(RelayDaemon::SourceCatalog) }
  let(:headers) { { "HTTP_AUTHORIZATION" => "Bearer source-token" } }
  before do
    app.set(:relay_config, RelayDaemon::Config.new(daemon_token: "source-token", host: "127.0.0.1", port: 7777, db_path: "unused"))
    app.set(:source_catalog, catalog)
  end
  after { app.set(:source_catalog, nil) }
  it "authenticates discovery and refresh, and reports unavailable configuration" do
    get "/model-sources"
    expect(last_response.status).to eq(401)
    post "/model-sources/refresh"
    expect(last_response.status).to eq(401)
    allow(catalog).to receive(:catalog).with(no_args).and_return([])
    get "/model-sources", {}, headers
    expect(last_response.status).to eq(200)
    expect(catalog).to receive(:catalog).with(refresh: true).and_return([])
    post "/model-sources/refresh", "", headers
    expect(last_response.status).to eq(200)
    app.set(:source_catalog, nil)
    get "/model-sources", {}, headers
    expect(last_response.status).to eq(503)
    post "/model-sources/refresh", "", headers
    expect(last_response.status).to eq(503)
  end
end
