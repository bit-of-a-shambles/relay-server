# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/provider_store"
require "json"
require "tmpdir"

RSpec.describe "Providers API" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }
  let(:store)   { RelayDaemon::ProviderStore.new(db) }
  let(:token)   { "providers-test-token" }
  let(:routing_config_path) { File.join(Dir.mktmpdir, "routing.json") }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
      routing_config_path: routing_config_path
    ))
    RelayDaemon::App.set(:provider_store, store)
    RelayDaemon::App.set(:stats_db, db)
  end

  after { db.connection.close }

  def auth_headers
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def post_provider(body)
    post "/providers", body.to_json, { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
  end

  # ----- GET /providers -----

  describe "GET /providers" do
    it "returns 401 without a token" do
      get "/providers"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when the provider store is not configured" do
      RelayDaemon::App.set(:provider_store, nil)
      get "/providers", {}, auth_headers
      expect(last_response.status).to eq(503)
    end

    it "returns 200 and an empty array initially" do
      get "/providers", {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq([])
    end

    it "lists providers without the raw api key, with hasApiKey instead" do
      store.create(name: "myvllm", base_url: "http://localhost:8000", api_key: "secret", models: ["llama-3"])
      store.create(name: "nokey", base_url: "http://localhost:9000")

      get "/providers", {}, auth_headers
      body = JSON.parse(last_response.body)

      with_key = body.find { |p| p["name"] == "myvllm" }
      expect(with_key["hasApiKey"]).to be true
      expect(with_key).not_to have_key("apiKey")
      expect(with_key["baseUrl"]).to eq("http://localhost:8000")
      expect(with_key["models"]).to eq(["llama-3"])

      without_key = body.find { |p| p["name"] == "nokey" }
      expect(without_key["hasApiKey"]).to be false
      expect(without_key).not_to have_key("apiKey")
    end
  end

  # ----- POST /providers -----

  describe "POST /providers (success)" do
    it "returns 201 and the created provider without the raw api key" do
      post_provider(name: "myvllm", baseUrl: "http://localhost:8000", apiKey: "secret", models: ["llama-3", "qwen"])

      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body).to eq(
        "name" => "myvllm", "baseUrl" => "http://localhost:8000",
        "hasApiKey" => true, "models" => ["llama-3", "qwen"]
      )
    end

    it "defaults models to an empty list and hasApiKey to false when omitted" do
      post_provider(name: "myvllm", baseUrl: "http://localhost:8000")

      body = JSON.parse(last_response.body)
      expect(body["models"]).to eq([])
      expect(body["hasApiKey"]).to be false
    end

    it "writes the routing config file with the new provider" do
      post_provider(name: "myvllm", baseUrl: "http://localhost:8000", apiKey: "secret")

      parsed = JSON.parse(File.read(routing_config_path))
      expect(parsed["providers"]["myvllm"]).to eq("baseUrl" => "http://localhost:8000", "apiKey" => "secret")
    end

    it "does not write a config file when no routing config path is set" do
      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path
      ))
      post_provider(name: "myvllm", baseUrl: "http://localhost:8000")
      expect(last_response.status).to eq(201)
      expect(File.exist?(routing_config_path)).to be false
    end

    it "still creates the provider when no database is configured for the config write" do
      RelayDaemon::App.set(:stats_db, nil)
      post_provider(name: "myvllm", baseUrl: "http://localhost:8000")
      expect(last_response.status).to eq(201)
      expect(File.exist?(routing_config_path)).to be false
    end
  end

  describe "POST /providers (validation)" do
    it "returns 422 when name is missing" do
      post_provider(baseUrl: "http://localhost:8000")
      expect(last_response.status).to eq(422)
    end

    it "returns 422 when baseUrl is missing" do
      post_provider(name: "myvllm")
      expect(last_response.status).to eq(422)
    end

    it "returns 422 for a name that doesn't match [a-z0-9_-]+" do
      post_provider(name: "My Provider!", baseUrl: "http://localhost:8000")
      expect(last_response.status).to eq(422)
    end

    it "returns 422 for the reserved name 'openrouter'" do
      post_provider(name: "openrouter", baseUrl: "http://localhost:8000")
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to include("reserved")
    end

    it "returns 422 for a non-http(s) baseUrl" do
      post_provider(name: "myvllm", baseUrl: "ftp://localhost:8000")
      expect(last_response.status).to eq(422)
    end

    it "returns 409 on duplicate name" do
      store.create(name: "myvllm", base_url: "http://localhost:8000")
      post_provider(name: "myvllm", baseUrl: "http://localhost:9000")
      expect(last_response.status).to eq(409)
    end

    it "returns 400 on non-JSON body" do
      post "/providers", "not json", { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)
    end

    it "returns 401 without a token" do
      post "/providers", { name: "myvllm", baseUrl: "http://localhost:8000" }.to_json,
           "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when the provider store is not configured" do
      RelayDaemon::App.set(:provider_store, nil)
      post_provider(name: "myvllm", baseUrl: "http://localhost:8000")
      expect(last_response.status).to eq(503)
    end
  end

  # ----- DELETE /providers/:name -----

  describe "DELETE /providers/:name" do
    it "returns 401 without a token" do
      delete "/providers/myvllm"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when the provider store is not configured" do
      RelayDaemon::App.set(:provider_store, nil)
      delete "/providers/myvllm", {}, auth_headers
      expect(last_response.status).to eq(503)
    end

    it "returns 404 for an unknown provider" do
      delete "/providers/nope", {}, auth_headers
      expect(last_response.status).to eq(404)
    end

    it "removes an existing provider and returns 204" do
      store.create(name: "myvllm", base_url: "http://localhost:8000")
      delete "/providers/myvllm", {}, auth_headers
      expect(last_response.status).to eq(204)
      expect(store.all).to eq([])
    end

    it "rewrites the routing config file to drop the deleted provider" do
      store.create(name: "myvllm", base_url: "http://localhost:8000")
      post_provider(name: "keepme", baseUrl: "http://localhost:9000")

      delete "/providers/myvllm", {}, auth_headers

      parsed = JSON.parse(File.read(routing_config_path))
      expect(parsed["providers"]).to eq("keepme" => { "baseUrl" => "http://localhost:9000" })
    end
  end
end
