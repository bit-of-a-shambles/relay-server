# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/router_supervisor"

RSpec.describe RelayDaemon::RouterSupervisor do
  # Commands — use system ruby so tests don't depend on project setup.
  let(:slow_command)       { ["ruby", "-e", "sleep 60"] }
  let(:fast_exit_command)  { ["ruby", "-e", "exit 0"] }
  let(:term_ignoring_cmd)  { ["ruby", "-e", 'trap("TERM") {}; sleep 60'] }

  def instant_sleeper
    ->(_n) {} # records nothing, returns immediately
  end

  # ----- Initial state -----

  describe "#status before start" do
    it "is :stopped" do
      expect(described_class.new(slow_command).status).to eq(:stopped)
    end
  end

  # ----- start / stop -----

  describe "#start / #stop with a long-running process" do
    it "transitions to :running then :stopped" do
      sup = described_class.new(slow_command)
      sup.start
      sleep 0.05 # brief sync wait for process to spawn
      expect(sup.status).to eq(:running)
      sup.stop
      expect(sup.status).to eq(:stopped)
    end

    it "stop is idempotent when already stopped" do
      sup = described_class.new(slow_command)
      expect { sup.stop }.not_to raise_error
      expect(sup.status).to eq(:stopped)
    end

    it "raises if start is called when already running" do
      sup = described_class.new(slow_command)
      sup.start
      sleep 0.05
      expect { sup.start }.to raise_error("RouterSupervisor already started")
      sup.stop
    end
  end

  # ----- Restart / backoff -----

  describe "automatic restart with backoff" do
    it "restarts on unexpected exit and calls sleeper with increasing backoff" do
      delays = []
      ready = Queue.new

      sleeper = ->(n) {
        delays << n
        ready.push(n)
      }

      sup = described_class.new(
        fast_exit_command,
        backoff: [1, 2, 4, 8],
        sleeper: sleeper
      )
      sup.start

      # Wait for 3 backoff events
      3.times { ready.pop }

      sup.stop

      expect(delays.first(3)).to eq([1, 2, 4])
      expect(sup.status).to eq(:stopped)
    end

    it "clamps backoff delay at the last value after exhausting the schedule" do
      delays = []
      ready = Queue.new

      sleeper = ->(n) {
        delays << n
        ready.push(n)
      }

      sup = described_class.new(
        fast_exit_command,
        backoff: [1, 2],
        sleeper: sleeper
      )
      sup.start

      # 4 restarts: delays should be [1, 2, 2, 2]
      4.times { ready.pop }
      sup.stop

      expect(delays.first(4)).to eq([1, 2, 2, 2])
    end

    it "passes through :restarting status during the backoff sleep" do
      status_during_sleep = []
      ready = Queue.new
      sup = nil

      sleeper = ->(n) {
        status_during_sleep << sup&.status # rubocop:disable Style/SafeNavigationChainLength
        ready.push(n)
      }

      sup = described_class.new(fast_exit_command, backoff: [1], sleeper: sleeper)
      sup.start
      ready.pop
      sup.stop

      expect(status_during_sleep.first).to eq(:restarting)
    end

    it "stops cleanly when stop is called during the backoff sleep" do
      # Validates the CHECK-A branch (stopping? at top of loop after a restart)
      reached_second_backoff = Queue.new

      sleeper = ->(n) {
        reached_second_backoff.push(n)
        # Yield to let stop() run between sleeper returning and next loop top
        Thread.pass
      }

      sup = described_class.new(
        fast_exit_command,
        backoff: [0, 0],
        sleeper: sleeper
      )
      sup.start
      reached_second_backoff.pop # first backoff
      reached_second_backoff.pop # second — now stop while loop might be at top
      sup.stop

      expect(sup.status).to eq(:stopped)
    end
  end

  # ----- KILL timer (send KILL when process ignores TERM) -----

  describe "KILL fallback" do
    it "sends KILL when the process ignores TERM" do
      sup = described_class.new(
        term_ignoring_cmd,
        sleeper: instant_sleeper,
        kill_timeout: 0  # immediate KILL in tests
      )
      sup.start
      sleep 0.05 # wait for process to start
      sup.stop
      expect(sup.status).to eq(:stopped)
    end

    it "timer no-ops when @pid is nil (process already reaped before KILL check)" do
      # This covers the `if p2` false branch in the timer thread.
      # Approach: stop while in backoff — at that point @pid is nil.
      in_backoff = Queue.new

      sleeper = ->(n) {
        if n == 0  # kill_timeout sentinel — return immediately
        elsif in_backoff.empty?
          in_backoff.push(:in_backoff)
          sleep 0.05 # hold here so test can call stop while @pid is nil
        end
      }

      sup = described_class.new(
        fast_exit_command,
        backoff: [1],
        sleeper: sleeper,
        kill_timeout: 0
      )
      sup.start
      in_backoff.pop            # wait until process has exited and @pid is nil
      sup.stop                  # timer fires immediately; @pid is nil → if p2 is false
      expect(sup.status).to eq(:stopped)
    end
  end

  # ----- ESRCH rescue in signal_process -----

  describe "#signal_process rescue" do
    it "does not raise when the process is already gone" do
      # Spawn and reap a process so the pid is stale
      pid = Process.spawn("true")
      Process.wait(pid)
      sup = described_class.new(slow_command)
      expect { sup.send(:signal_process, pid, "TERM") }.not_to raise_error
    end
  end
end
