# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/db"
require "relay_daemon/provider_store"
require "tmpdir"

RSpec.describe RelayDaemon::ProviderStore do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }

  after { db.connection.close }

  subject(:store) { described_class.new(db) }

  describe "#all" do
    it "returns an empty array initially" do
      expect(store.all).to eq([])
    end

    it "returns created providers ordered by name, including the raw api key" do
      store.create(name: "zeta", base_url: "https://zeta.example.com")
      store.create(name: "alpha", base_url: "https://alpha.example.com", api_key: "secret")

      names = store.all.map { |p| p["name"] }
      expect(names).to eq(%w[alpha zeta])

      alpha = store.all.find { |p| p["name"] == "alpha" }
      expect(alpha["apiKey"]).to eq("secret")
      expect(alpha["baseUrl"]).to eq("https://alpha.example.com")
      expect(alpha["models"]).to eq([])
    end
  end

  describe "#create" do
    it "creates a provider with no api key and an empty models list by default" do
      provider = store.create(name: "myvllm", base_url: "http://localhost:8000")
      expect(provider).to eq(
        "name" => "myvllm", "baseUrl" => "http://localhost:8000", "apiKey" => nil, "models" => []
      )
    end

    it "persists a declared models list" do
      provider = store.create(name: "myvllm", base_url: "http://localhost:8000", models: ["llama-3", "qwen"])
      expect(provider["models"]).to eq(["llama-3", "qwen"])
      expect(store.all.first["models"]).to eq(["llama-3", "qwen"])
    end

    it "rejects names that don't match [a-z0-9_-]+" do
      expect { store.create(name: "My Provider!", base_url: "https://example.com") }
        .to raise_error(ArgumentError, /name must match/)
    end

    it "rejects the reserved name 'openrouter'" do
      expect { store.create(name: "openrouter", base_url: "https://example.com") }
        .to raise_error(ArgumentError, /reserved/)
    end

    it "rejects a non-http(s) base url" do
      expect { store.create(name: "myvllm", base_url: "ftp://example.com") }
        .to raise_error(ArgumentError, /http/)
    end

    it "raises SQLite3::ConstraintException on duplicate name" do
      store.create(name: "myvllm", base_url: "http://localhost:8000")
      expect { store.create(name: "myvllm", base_url: "http://localhost:9000") }
        .to raise_error(SQLite3::ConstraintException)
    end
  end

  describe "#delete" do
    it "returns false for an unknown name" do
      expect(store.delete("nope")).to be false
    end

    it "removes an existing provider and returns true" do
      store.create(name: "myvllm", base_url: "http://localhost:8000")
      expect(store.delete("myvllm")).to be true
      expect(store.all).to eq([])
    end
  end
end
