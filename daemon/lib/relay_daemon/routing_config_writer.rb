# typed: true
# frozen_string_literal: true

require "json"
require "fileutils"
require "sorbet-runtime"
require_relative "eval_store"
require_relative "provider_store"

module RelayDaemon
  # Turns accumulated test outcomes into a routing config the TypeScript router
  # hot-reloads (RELAY_ROUTING_CONFIG). Within each tier the models are reordered
  # so the one with the best measured test pass rate (given enough samples) comes
  # first — the router routes each tier to its first model, so routing now learns
  # from whether tests actually passed, unlike OpenRouter's outcome-blind routing.
  class RoutingConfigWriter
    extend T::Sig

    # Tested session outcomes a model needs before its pass rate is allowed to
    # reorder a tier (avoids overreacting to one or two early results).
    MIN_SAMPLES = 5

    DEFAULT_BASE_CONFIG = T.let(
      {
        "tiers" => {
          "0" => ["deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-pro", "openrouter-pareto-code"],
          "1" => ["openai/gpt-5.5", "x-ai/grok-4.5", "z-ai/glm-5.2", "openrouter-auto"],
          "2" => ["openai/gpt-5.6-terra", "openai/gpt-5.6-luna"],
          "3" => ["openai/gpt-5.6-sol", "anthropic/claude-fable-5"]
        },
        "rules" => [
          { "when" => "requestedModel contains 'haiku'", "tier" => 0 },
          { "when" => "requestedModel contains 'flash'", "tier" => 0 },
          { "when" => "promptTokens > 60000", "tier" => 2 },
          { "when" => "default", "tier" => 1 }
        ],
        "qualityDial" => { "default" => 5 },
        "frontierModel" => "openai/gpt-5.6-sol",
        "targets" => {
          "openrouter-auto" => { "model" => "openrouter/auto-beta" },
          "openrouter-pareto-code" => { "model" => "openrouter/pareto-code" }
        },
        "providers" => {}
      }.freeze,
      T::Hash[String, T.untyped]
    )

    # Config files can carry inline provider API keys, so they must not be
    # world/group readable.
    FILE_MODE = 0o600

    sig do
      params(
        eval_store: EvalStore,
        base_config: T::Hash[String, T.untyped],
        min_samples: Integer,
        provider_store: T.nilable(ProviderStore)
      ).void
    end
    def initialize(eval_store, base_config: DEFAULT_BASE_CONFIG, min_samples: MIN_SAMPLES, provider_store: nil)
      @eval_store     = eval_store
      @base_config    = base_config
      @min_samples    = min_samples
      @provider_store = provider_store
    end

    # Routing-config hash (router schema) with each tier's models reordered by
    # measured pass rate, and a "providers" section merged in from every
    # daemon-managed custom provider (see ProviderStore, M45).
    sig { returns(T::Hash[String, T.untyped]) }
    def config
      rates = pass_rates
      tiers = T.cast(@base_config.fetch("tiers"), T::Hash[String, T::Array[String]])
      reordered = tiers.transform_values { |models| reorder(models, rates) }
      @base_config.merge("tiers" => reordered, "providers" => providers_section)
    end

    # Writes the config atomically (parent dir created) so the router's
    # mtime-based reload picks it up without a torn read. Mode 0600 since the
    # "providers" section can carry inline API keys.
    sig { params(path: String).void }
    def write!(path)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(config))
      File.chmod(FILE_MODE, tmp)
      File.rename(tmp, path)
    end

    private

    # Router-schema providers map (name => { baseUrl, apiKey }) built from
    # every stored provider. The apiKey is inlined (rather than apiKeyEnv)
    # because these providers are persisted directly by the daemon, not
    # sourced from the router operator's environment. Falls back to whatever
    # the base config already had when no provider store is configured.
    sig { returns(T::Hash[String, T.untyped]) }
    def providers_section
      store = @provider_store
      return T.cast(@base_config.fetch("providers", {}), T::Hash[String, T.untyped]) if store.nil?

      store.all.each_with_object({}) do |provider, out|
        entry = { "baseUrl" => provider.fetch("baseUrl") }
        api_key = provider["apiKey"]
        entry["apiKey"] = api_key unless api_key.nil?
        out[provider.fetch("name")] = entry
      end
    end

    # model => pass rate, only for models with a known rate and enough samples.
    sig { returns(T::Hash[String, Float]) }
    def pass_rates
      out = {}
      @eval_store.model_outcomes.each do |o|
        next if o[:passRate].nil?
        next if o[:outcomesWithTests].to_i < @min_samples

        out[o[:model]] = o[:passRate].to_f
      end
      out
    end

    # Stable reorder: models with a measured rate sort first by rate desc;
    # the rest keep their base order after them.
    sig { params(models: T::Array[String], rates: T::Hash[String, Float]).returns(T::Array[String]) }
    def reorder(models, rates)
      scored, unscored = models.partition { |m| rates.key?(m) }
      scored.sort_by! { |m| -T.must(rates[m]) }
      scored + unscored
    end
  end
end
