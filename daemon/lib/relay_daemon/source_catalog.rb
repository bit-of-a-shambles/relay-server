# typed: true
# frozen_string_literal: true

require "json"
require "net/http"
require "sorbet-runtime"
require_relative "provider_store"
require_relative "open_router_models"

module RelayDaemon
  # Model discovery runs on the Mac, so loopback endpoints never mean the phone.
  # The transport and clock seams keep every automated test off the network.
  class SourceCatalog
    extend T::Sig
    PRESETS = T.let({
      "ollama" => ["Ollama", "http://127.0.0.1:11434/v1", "local"],
      "lmstudio" => ["LM Studio", "http://127.0.0.1:1234/v1", "local"],
      "doubleword" => ["Doubleword", "https://api.doubleword.ai/v1", "cloud"]
    }.freeze, T::Hash[String, T::Array[String]])

    sig do
      params(store: ProviderStore, open_router: OpenRouterModels, env: T::Hash[String, String],
             transport: T.nilable(T.proc.params(url: String, key: T.nilable(String)).returns(T::Hash[Symbol, T.untyped])),
             clock: T.proc.returns(Float)).void
    end
    def initialize(store:, open_router:, env: ENV.to_h, transport: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f })
      @store, @open_router, @env, @clock = store, open_router, env, clock
      @transport = transport
      @cache = T.let({}, T::Hash[String, T::Hash[String, T.untyped]])
      @mutex = T.let(Mutex.new, Mutex)
    end

    sig { params(refresh: T::Boolean).returns(T::Array[T::Hash[String, T.untyped]]) }
    def catalog(refresh: false)
      @mutex.synchronize do
        upstream = @open_router.catalog
        router = { "providerId" => "openrouter", "name" => "OpenRouter", "kind" => "cloud",
                   "baseUrl" => "https://openrouter.ai/api/v1", "models" => upstream["openRouter"],
                   "status" => @env.fetch("OPENROUTER_API_KEY", "").empty? ? "auth_required" : upstream["openRouterStatus"],
                   "hasApiKey" => !@env.fetch("OPENROUTER_API_KEY", "").empty?, "inferenceModes" => ["realtime"] }
        [router] + connections.map { |provider| discover(provider, refresh: refresh) }
      end
    end

    # Private router configuration, deliberately separate from the public catalog.
    sig { returns(T::Hash[String, T.untyped]) }
    def routing_providers
      connections.each_with_object({}) do |provider, result|
        entry = { "baseUrl" => provider.fetch("baseUrl") }
        entry["apiKey"] = provider["apiKey"] unless provider["apiKey"].nil?
        result[provider.fetch("name")] = entry
      end
    end

    private

    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def connections
      stored = @store.all
      defaults = PRESETS.filter_map do |id, (_name, url, _kind)|
        next if stored.any? { |provider| provider["name"] == id }

        { "name" => id, "baseUrl" => url, "apiKey" => id == "doubleword" ? @env["DOUBLEWORD_API_KEY"] : nil, "models" => [] }
      end
      stored + defaults
    end

    sig { params(provider: T::Hash[String, T.untyped], refresh: T::Boolean).returns(T::Hash[String, T.untyped]) }
    def discover(provider, refresh:)
      id = provider.fetch("name")
      preset = PRESETS[id]
      key = provider["apiKey"]
      fingerprint = JSON.generate([provider["baseUrl"], key, provider["models"]])
      previous = @cache[id]
      if !refresh && previous && previous["fingerprint"] == fingerprint && previous["expires"] > @clock.call
        return previous.fetch("public")
      end
      models = provider.fetch("models").dup
      status = "unavailable"
      begin
        if id == "doubleword" && key.to_s.empty?
          status = "auth_required"
        else
          transport = @transport
          response = transport.nil? ? fetch_models(provider.fetch("baseUrl"), key) : transport.call(provider.fetch("baseUrl"), key)
          if [401, 403].include?(response[:status])
            status = "auth_required"
          else
            raise IOError, "model discovery failed" unless response[:status] == 200

            body = JSON.parse(response.fetch(:body))
            entries = body.fetch("data")
            raise IOError, "invalid model list" unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) && entry["id"].is_a?(String) && !entry["id"].strip.empty? }

            models = entries.map { |entry| entry.fetch("id") }.uniq.sort
            status = "ready"
          end
        end
      rescue JSON::ParserError, KeyError, TypeError, IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
        models = previous["public"]["models"] if previous && previous["fingerprint"] == fingerprint
        status = models.empty? ? "unavailable" : "cached"
      end
      public_value = { "providerId" => id, "name" => preset.nil? ? id : preset[0],
                       "baseUrl" => provider.fetch("baseUrl"), "kind" => preset.nil? ? "custom" : preset[2],
                       "hasApiKey" => !key.to_s.empty?, "models" => models, "status" => status,
                       "inferenceModes" => id == "doubleword" ? %w[realtime async] : ["realtime"] }
      @cache[id] = { "fingerprint" => fingerprint, "expires" => @clock.call + 60, "public" => public_value }
      public_value
    end

    sig { params(url: String, key: T.nilable(String)).returns(T::Hash[Symbol, T.untyped]) }
    def fetch_models(url, key)
      uri = URI("#{url.delete_suffix('/')}/models")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{key}" unless key.to_s.empty?
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 5) { |http| http.request(request) }
      { status: response.code.to_i, body: response.body.to_s }
    end
  end
end
