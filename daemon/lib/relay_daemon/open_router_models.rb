# typed: true
# frozen_string_literal: true

require "json"
require "net/http"
require "sorbet-runtime"

module RelayDaemon
  # Public metadata only. API keys and conversation content never leave the Mac here.
  class OpenRouterModels
    extend T::Sig

    class CatalogError < StandardError; end

    sig do
      params(
        transport: T.nilable(T.proc.params(offset: Integer).returns(String)),
        clock: T.proc.returns(Float)
      ).void
    end
    def initialize(transport: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f })
      @transport = T.let(transport || ->(offset) { fetch_page(offset) }, T.proc.params(offset: Integer).returns(String))
      @clock = clock
      @models = T.let([], T::Array[String])
      @next_refresh = T.let(0.0, Float)
      @mutex = T.let(Mutex.new, Mutex)
      @status = T.let("unavailable", String)
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def catalog
      @mutex.synchronize do
        if @clock.call >= @next_refresh
          begin
            @models = load_models
            @status = "live"
            @next_refresh = @clock.call + 3600
          rescue CatalogError, JSON::ParserError, KeyError, TypeError, IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
            @status = @models.empty? ? "unavailable" : "cached"
            @next_refresh = @clock.call + 60
          end
        end
        { "openRouter" => @models.dup, "openRouterStatus" => @status }
      end
    end

    private

    sig { returns(T::Array[String]) }
    def load_models
      models = T.let([], T::Array[String])
      offset = 0
      loop do
        page = JSON.parse(@transport.call(offset))
        raise CatalogError, "invalid catalog" unless page.is_a?(Hash) && page["data"].is_a?(Array)

        entries = T.cast(page.fetch("data"), T::Array[T.untyped])
        raise CatalogError, "empty catalog page" if entries.empty?

        entries.each do |entry|
          raise CatalogError, "invalid model" unless entry.is_a?(Hash) && entry["id"].is_a?(String) && !entry["id"].strip.empty?

          models << entry["id"].strip
        end
        offset += entries.length
        break unless page.dig("links", "next")
      end
      models.uniq.sort
    end

    sig { params(offset: Integer).returns(String) }
    def fetch_page(offset)
      uri = URI("https://openrouter.ai/api/v1/models?offset=#{offset}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      raise CatalogError, "catalog request failed" unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s
    end
  end
end
