# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

module RelayDaemon
  # Thread-safe in-process pub/sub for daemon events.
  # Every published event is a hash:
  #   {"type" => "...", "payload" => {...}}
  class EventBus
    extend T::Sig

    Subscriber = T.type_alias { T.proc.params(arg0: T::Hash[String, T.untyped]).void }

    sig { void }
    def initialize
      @mutex       = T.let(Mutex.new, Mutex)
      @subscribers = T.let({}, T::Hash[Integer, Subscriber])
      @next_id     = T.let(0, Integer)
    end

    # Registers a subscriber; returns an id for unsubscribe.
    sig { params(block: Subscriber).returns(Integer) }
    def subscribe(&block)
      @mutex.synchronize do
        @next_id += 1
        @subscribers[@next_id] = block
        @next_id
      end
    end

    sig { params(id: Integer).void }
    def unsubscribe(id)
      @mutex.synchronize { @subscribers.delete(id) }
    end

    # Delivers the event to all subscribers. A raising subscriber does not
    # prevent delivery to the others.
    sig { params(type: String, payload: T::Hash[String, T.untyped]).void }
    def publish(type:, payload: {})
      event = { "type" => type, "payload" => payload }
      subs = @mutex.synchronize { @subscribers.values.dup }
      subs.each do |sub|
        sub.call(event)
      rescue StandardError
        nil
      end
    end
  end
end
