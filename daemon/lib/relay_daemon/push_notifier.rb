# typed: true
# frozen_string_literal: true

require "json"
require "net/http"
require "sorbet-runtime"
require "uri"
require_relative "push_device_store"

module RelayDaemon
  module PushHttp
    extend T::Helpers
    extend T::Sig

    interface!

    sig do
      abstract.params(
        uri: URI::Generic,
        body: String,
        headers: T::Hash[String, String],
        timeout: Numeric
      ).returns(Integer)
    end
    def post(uri, body, headers, timeout); end
  end

  module PushLogger
    extend T::Helpers
    extend T::Sig

    interface!

    sig { abstract.params(message: String).void }
    def log(message); end
  end

  class StderrPushLogger
    extend T::Sig
    include PushLogger

    sig { params(io: T.untyped).void }
    def initialize(io = $stderr)
      @io = io
    end

    sig { override.params(message: String).void }
    def log(message)
      @io.puts("daemon: #{message}")
    end
  end

  # Production HTTP adapter kept separate so PushNotifier can use a fake in specs.
  class NetPushHttp
    extend T::Sig
    include PushHttp

    sig do
      override.params(
        uri: URI::Generic,
        body: String,
        headers: T::Hash[String, String],
        timeout: Numeric
      ).returns(Integer)
    end
    def post(uri, body, headers, timeout)
      http = Net::HTTP.new(T.must(uri.host), T.must(uri.port))
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      T.unsafe(http).write_timeout = timeout
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      headers.each { |name, value| request[name] = value }
      request.body = body
      response = http.start { |client| client.request(request) }
      response.code.to_i
    end
  end

  # Best-effort forwarding of lifecycle events through one bounded worker.
  class PushNotifier
    extend T::Sig

    AGENT_FINISHED = "agent_finished"
    TESTS_FINISHED = "tests_finished"
    NEEDS_REVIEW = "needs_review"
    CATEGORIES = T.let([AGENT_FINISHED, TESTS_FINISHED, NEEDS_REVIEW].freeze, T::Array[String])

    HTTP_TIMEOUT_SECONDS = 3
    DELIVERY_BUDGET_SECONDS = 3
    DEFAULT_QUEUE_CAPACITY = 32
    MAX_DEVICES_PER_EVENT = 64

    sig do
      params(
        relay_url: T.nilable(String),
        environment: String,
        device_store: PushDeviceStore,
        relay_token: T.nilable(String),
        http: PushHttp,
        logger: PushLogger,
        queue_capacity: Integer,
        max_devices_per_event: Integer,
        delivery_budget_seconds: Numeric
      ).void
    end
    def initialize(
      relay_url:,
      environment:,
      device_store:,
      relay_token: nil,
      http: NetPushHttp.new,
      logger: StderrPushLogger.new,
      queue_capacity: DEFAULT_QUEUE_CAPACITY,
      max_devices_per_event: MAX_DEVICES_PER_EVENT,
      delivery_budget_seconds: DELIVERY_BUDGET_SECONDS
    )
      @relay_url = relay_url
      @relay_token = relay_token
      @environment = environment
      @device_store = device_store
      @http = http
      @logger = logger
      @queue = T.let(SizedQueue.new(queue_capacity), SizedQueue)
      @max_devices_per_event = max_devices_per_event
      @delivery_budget_seconds = delivery_budget_seconds
      @state_mutex = T.let(Mutex.new, Mutex)
      @idle = T.let(ConditionVariable.new, ConditionVariable)
      @pending = T.let(0, Integer)
      @accepting = T.let(!relay_url.nil? && !relay_token.nil?, T::Boolean)
      @worker = T.let(@accepting ? Thread.new { worker_loop } : nil, T.nilable(Thread))
    end

    # Enqueues without waiting for HTTP or SQLite. Returns false when disabled,
    # shutting down, invalid, or full; lifecycle callers never receive errors.
    sig { params(category: String).returns(T::Boolean) }
    def notify(category)
      return false unless @state_mutex.synchronize { @accepting }

      unless CATEGORIES.include?(category)
        safe_log("ignored invalid push category")
        return false
      end

      enqueued = @state_mutex.synchronize do
        begin
          @queue.push(category, true)
          @pending += 1
          true
        rescue ThreadError, ClosedQueueError
          false
        end
      end
      safe_log("push queue full; dropped #{category}") unless enqueued || !@accepting
      enqueued
    rescue StandardError => e
      safe_log("push enqueue failed (#{e.class})")
      false
    end

    # Test/lifecycle seam: waits for queued and active work, never forever.
    sig { params(timeout: Numeric).returns(T::Boolean) }
    def wait_until_idle(timeout:)
      deadline = monotonic_now + timeout
      @state_mutex.synchronize do
        while @pending.positive?
          remaining = deadline - monotonic_now
          return false if remaining <= 0

          @idle.wait(@state_mutex, remaining)
        end
      end
      true
    end

    # Stops accepting work, drains the bounded queue, and joins the sole worker.
    sig { params(timeout: Numeric).returns(T::Boolean) }
    def shutdown(timeout: 5.0)
      worker = @worker
      return true if worker.nil?

      @state_mutex.synchronize do
        if @accepting
          @accepting = false
          @queue.close
        end
      end
      stopped = !worker.join(timeout).nil?
      safe_log("push worker did not stop before shutdown timeout") unless stopped
      stopped
    end

    private

    sig { void }
    def worker_loop
      loop do
        category = @queue.pop
        break if category.nil?

        begin
          process_category(category)
        ensure
          complete_one
        end
      end
    ensure
      begin
        @device_store.close_current_connection
      rescue StandardError => e
        safe_log("push worker cleanup failed (#{e.class})")
      end
    end

    sig { params(category: String).void }
    def process_category(category)
      relay_url = T.must(@relay_url)
      relay_token = T.must(@relay_token)
      uri = URI.parse(relay_url)
      devices = @device_store.all(limit: @max_devices_per_event + 1)
      if devices.length > @max_devices_per_event
        safe_log("push device limit reached; remaining devices skipped")
        devices = devices.first(@max_devices_per_event)
      end

      deadline = monotonic_now + @delivery_budget_seconds
      devices.each do |device|
        remaining = deadline - monotonic_now
        if remaining <= 0
          safe_log("push delivery budget exceeded for #{category}")
          break
        end

        timeout = [HTTP_TIMEOUT_SECONDS.to_f, remaining].min
        deliver(uri, relay_token, category, device.fetch("deviceToken"), timeout)
      end
    rescue StandardError => e
      safe_log("push worker failed (#{e.class})")
    end

    sig do
      params(
        uri: URI::Generic,
        relay_token: String,
        category: String,
        device_token: String,
        timeout: Numeric
      ).void
    end
    def deliver(uri, relay_token, category, device_token, timeout)
      payload = JSON.generate(
        "deviceToken" => device_token,
        "category" => category,
        "environment" => @environment
      )
      status = @http.post(
        uri,
        payload,
        { "Authorization" => "Bearer #{relay_token}" },
        timeout
      )
      safe_log("push relay returned HTTP #{status} for #{category}") unless (200...300).cover?(status)
    rescue StandardError => e
      safe_log("push delivery failed (#{e.class})")
    end

    sig { void }
    def complete_one
      @state_mutex.synchronize do
        @pending -= 1
        @idle.broadcast if @pending.zero?
      end
    end

    sig { params(message: String).void }
    def safe_log(message)
      @logger.log(message)
    rescue StandardError
      nil
    end

    sig { returns(Float) }
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
    end
  end
end
