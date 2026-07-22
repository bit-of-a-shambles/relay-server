# typed: true
# frozen_string_literal: true

require "json"
require "sorbet-runtime"
require_relative "provider_store"

module RelayDaemon
  # Backs `GET /models`: reads the routing-config JSON that RoutingConfigWriter
  # writes (see routing_config_writer.rb / Config#routing_config_path) and
  # exposes it as tiers + frontier model for clients like the iOS model
  # picker. Falls back to a built-in default when the file is absent or
  # unreadable so the endpoint always returns something sane before the
  # daemon has learned any outcomes.
  class ModelCatalog
    extend T::Sig

    # Cross-reference: keep this in sync with DEFAULT_ROUTING_CONFIG in
    # router/src/routing.ts. The two defaults must match or the picker will
    # show models the router wouldn't actually route to (and vice versa) —
    # check both files when changing either.
    DEFAULT_CONFIG = T.let(
      {
        "tiers" => {
          "0" => ["deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-pro", "openrouter-pareto-code"],
          "1" => ["openai/gpt-5.5", "x-ai/grok-4.5", "z-ai/glm-5.2", "openrouter-auto"],
          "2" => ["openai/gpt-5.6-terra", "openai/gpt-5.6-luna"],
          "3" => ["openai/gpt-5.6-sol", "anthropic/claude-fable-5"]
        },
        "frontierModel" => "openai/gpt-5.6-sol",
        "targets" => {
          "openrouter-auto" => { "model" => "openrouter/auto-beta" },
          "openrouter-pareto-code" => { "model" => "openrouter/pareto-code" }
        }
      }.freeze,
      T::Hash[String, T.untyped]
    )

    sig { params(routing_config_path: T.nilable(String), provider_store: T.nilable(ProviderStore)).void }
    def initialize(routing_config_path, provider_store: nil)
      @routing_config_path = routing_config_path
      @provider_store = provider_store
    end

    # { "tiers" => [{ "tier" => 0, "models" => [...] }, ...],
    #   "frontierModel" => "...", "source" => "file" | "default",
    #   "custom" => ["providerName::modelId", ...] }
    # Tiers are sorted ascending by tier number. "custom" lists every
    # daemon-managed provider's declared models (see ProviderStore, M45),
    # independent of the routing config file's source.
    sig { returns(T::Hash[String, T.untyped]) }
    def catalog
      config, source = load_config
      tiers = T.cast(config.fetch("tiers"), T::Hash[String, T.untyped])
      sorted_tiers = tiers.map { |tier, models| { "tier" => tier.to_i, "models" => models } }
                          .sort_by { |entry| T.cast(entry.fetch("tier"), Integer) }

      {
        "tiers" => sorted_tiers,
        "frontierModel" => config.fetch("frontierModel"),
        "source" => source,
        "custom" => custom_models
      }
    end

    private

    sig { returns(T::Array[String]) }
    def custom_models
      store = @provider_store
      return [] if store.nil?

      store.all.flat_map do |provider|
        T.cast(provider.fetch("models"), T::Array[String]).map { |model| "#{provider.fetch("name")}::#{model}" }
      end
    end

    # Reads and parses the routing config file, falling back to the built-in
    # default (with source "default") when there is no path configured, the
    # file doesn't exist, or it doesn't contain valid JSON.
    sig { returns([T::Hash[String, T.untyped], String]) }
    def load_config
      path = @routing_config_path
      return [DEFAULT_CONFIG, "default"] if path.nil?

      begin
        contents = File.read(path)
      rescue Errno::ENOENT
        return [DEFAULT_CONFIG, "default"]
      end

      begin
        parsed = JSON.parse(contents)
      rescue JSON::ParserError
        return [DEFAULT_CONFIG, "default"]
      end

      [T.cast(parsed, T::Hash[String, T.untyped]), "file"]
    end
  end
end
