# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

module RelayDaemon
  class RouterSupervisor
    extend T::Sig

    BACKOFF_DEFAULT = T.let([1, 2, 4, 8], T::Array[Integer])
    DEFAULT_SLEEPER = T.let(->(n) { sleep(n) }, T.proc.params(arg0: Numeric).void)

    sig do
      params(
        command: T::Array[String],
        env: T::Hash[String, String],
        backoff: T::Array[Integer],
        sleeper: T.proc.params(arg0: Numeric).void,
        kill_timeout: Numeric,
        cwd: T.nilable(String)
      ).void
    end
    def initialize(
      command,
      env: {},
      backoff: BACKOFF_DEFAULT,
      sleeper: DEFAULT_SLEEPER,
      kill_timeout: 5,
      cwd: nil
    )
      @command = command
      @env = env
      @backoff = backoff
      @sleeper = sleeper
      @kill_timeout = kill_timeout
      @cwd = T.let(cwd, T.nilable(String))
      @mutex = T.let(Mutex.new, Mutex)
      @status = T.let(:stopped, Symbol)
      @pid = T.let(nil, T.nilable(Integer))
      @stopping = T.let(false, T::Boolean)
      @thread = T.let(nil, T.nilable(Thread))
    end

    sig { void }
    def start
      @mutex.synchronize do
        raise "RouterSupervisor already started" unless @status == :stopped

        @stopping = false
        @status = :running
      end
      @thread = Thread.new { run_loop }
    end

    sig { void }
    def stop
      thread = T.let(nil, T.nilable(Thread))
      pid = T.let(nil, T.nilable(Integer))
      @mutex.synchronize do
        return unless %i[running restarting].include?(@status)

        @stopping = true
        thread = @thread
        pid = @pid
      end

      signal_process(pid, "TERM") if pid

      timer = Thread.new do
        @sleeper.call(@kill_timeout)
        p2 = @mutex.synchronize { @pid }
        signal_process(p2, "KILL") if p2
      end

      T.must(thread).join
      timer.kill
      timer.join
      @mutex.synchronize { @status = :stopped }
    end

    sig { returns(Symbol) }
    def status
      @mutex.synchronize { @status }
    end

    private

    sig { void }
    def run_loop
      attempt = 0
      loop do
        break if @mutex.synchronize { @stopping }

        pid = if @cwd.nil?
                T.unsafe(Process).spawn(@env, *@command)
              else
                T.unsafe(Process).spawn(@env, *@command, chdir: @cwd)
              end
        @mutex.synchronize { @pid = pid }
        Process.wait2(pid)
        @mutex.synchronize { @pid = nil }

        break if @mutex.synchronize { @stopping }

        @mutex.synchronize { @status = :restarting }
        delay = T.must(@backoff[[@backoff.size - 1, attempt].min])
        @sleeper.call(delay)
        attempt += 1
        @mutex.synchronize { @status = :running unless @stopping }
      end
      @mutex.synchronize { @status = :stopped }
    end

    sig { params(pid: Integer, sig_name: String).void }
    def signal_process(pid, sig_name)
      Process.kill(sig_name, pid)
    rescue Errno::ESRCH
      # Process already exited
    end
  end
end
