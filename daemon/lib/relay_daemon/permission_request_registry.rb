# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

module RelayDaemon
  # In-memory rendezvous between a blocked /internal/permission-requests call
  # (waiting on a live decision for one pending tool call) and the client
  # response that resolves it via POST /sessions/:id/permission-requests/:id.
  # Not persisted: a daemon restart mid-request simply times out the waiter,
  # which is the same "deny after timeout" behavior as an unreachable client.
  class PermissionRequestRegistry
    extend T::Sig

    sig { void }
    def initialize
      @mutex = Mutex.new
      @queues = T.let({}, T::Hash[String, Queue])
    end

    # Registers a new pending request id and blocks the calling thread until
    # either #resolve is called with that id, or timeout_seconds elapses.
    # Returns the decision ("allow"/"deny") or "deny" on timeout.
    sig { params(request_id: String, timeout_seconds: Numeric).returns(String) }
    def await(request_id, timeout_seconds:)
      queue = Queue.new
      @mutex.synchronize { @queues[request_id] = queue }

      queue.pop(timeout: timeout_seconds) || "deny"
    ensure
      @mutex.synchronize { @queues.delete(request_id) }
    end

    # Resolves a pending request with a client decision. Returns false if no
    # matching pending request is waiting (already resolved, timed out, or
    # unknown id).
    sig { params(request_id: String, decision: String).returns(T::Boolean) }
    def resolve(request_id, decision)
      queue = @mutex.synchronize { @queues[request_id] }
      return false if queue.nil?

      queue.push(decision)
      true
    end
  end
end
