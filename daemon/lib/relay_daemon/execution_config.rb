# typed: true
# frozen_string_literal: true

require "json"
require "sorbet-runtime"
require_relative "db"

module RelayDaemon
  # Public execution choices contain identifiers only, never credentials.
  class ExecutionConfig
    extend T::Sig

    HARNESS_IDS = T.let(%w[claude codex gemini copilot omp].freeze, T::Array[String])
    KEYS = T.let(%w[harnessId providerId modelId inferenceMode].freeze, T::Array[String])
    LEGACY = T.let({ "harnessId" => "claude", "providerId" => "openrouter", "modelId" => nil, "inferenceMode" => "realtime" }.freeze, T::Hash[String, T.untyped])

    sig { params(value: T.untyped).returns(T::Hash[String, T.untyped]) }
    def self.validate(value)
      raise ArgumentError, "execution must be an object" unless value.is_a?(Hash)
      raise ArgumentError, "unknown execution setting" unless (value.keys - KEYS).empty?

      result = LEGACY.merge(value)
      raise ArgumentError, "unknown harness" unless HARNESS_IDS.include?(result["harnessId"])
      provider = result["providerId"]
      raise ArgumentError, "providerId must be a provider identifier" unless provider.is_a?(String) && provider.match?(/\A[a-z0-9_-]+\z/)
      model = result["modelId"]
      raise ArgumentError, "modelId must be a nonblank string or null" unless model.nil? || (model.is_a?(String) && !model.strip.empty?)
      raise ArgumentError, "inferenceMode must be realtime or async" unless %w[realtime async].include?(result["inferenceMode"])
      raise ArgumentError, "async requires Doubleword" if result["inferenceMode"] == "async" && provider != "doubleword"

      result
    end

    sig { params(db: Db).void }
    def initialize(db)
      @db = db
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def defaults
      raw = @db.connection.get_first_value("SELECT execution_defaults FROM daemon_settings WHERE id = 1")
      raw.nil? ? LEGACY.dup : self.class.validate(JSON.parse(raw))
    end

    sig { params(value: T.untyped).returns(T::Hash[String, T.untyped]) }
    def update_defaults(value)
      config = self.class.validate(value)
      @db.connection.execute("UPDATE daemon_settings SET execution_defaults = ? WHERE id = 1", [JSON.generate(config)])
      config
    end
  end
end
