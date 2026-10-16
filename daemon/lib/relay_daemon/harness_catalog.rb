# typed: true
# frozen_string_literal: true

require "open3"
require "timeout"
require "sorbet-runtime"

module RelayDaemon
  class HarnessCatalog
    extend T::Sig

    NAMES = T.let({ "claude" => "Claude Code", "codex" => "Codex", "gemini" => "Gemini CLI", "copilot" => "GitHub Copilot CLI", "omp" => "Oh My Pi" }.freeze, T::Hash[String, String])

    CAPABILITIES = T.let({
      "claude" => { "permissionModes" => %w[full_auto ask_on_sensitive ask_every_time], "providers" => %w[openrouter custom] },
      "codex" => { "permissionModes" => %w[full_auto ask_on_sensitive], "providers" => %w[native openrouter doubleword] },
      "copilot" => { "permissionModes" => %w[full_auto ask_on_sensitive], "providers" => %w[native openrouter custom] },
      "gemini" => { "permissionModes" => %w[full_auto], "providers" => %w[native] },
      "omp" => { "permissionModes" => %w[full_auto], "providers" => %w[native openrouter custom] }
    }.freeze, T::Hash[String, T::Hash[String, T::Array[String]]])

    sig do
      params(env: T::Hash[String, String], home: String, timeout: Numeric, system_paths: T::Array[String],
             probe: T.nilable(T.proc.params(path: String).returns(T::Hash[Symbol, T.untyped]))).void
    end
    def initialize(env: ENV.to_h, home: Dir.home, timeout: 3, system_paths: ["/opt/homebrew/bin", "/usr/local/bin"], probe: nil)
      @env = env
      @home = home
      @timeout = timeout
      @system_paths = system_paths
      @probe = probe
      @mutex = T.let(Mutex.new, Mutex)
      @cached = T.let(nil, T.nilable(T::Array[T::Hash[String, T.untyped]]))
    end

    sig { params(refresh: T::Boolean).returns(T::Array[T::Hash[String, T.untyped]]) }
    def catalog(refresh: false)
      @mutex.synchronize do
        @cached = NAMES.map { |id, name| discover(id, name) } if refresh || @cached.nil?
        T.must(@cached).map(&:dup)
      end
    end

    private

    sig { params(id: String, name: String).returns(T::Hash[String, T.untyped]) }
    def discover(id, name)
      override = @env["RELAY_HARNESS_#{id.upcase}_PATH"]
      dirs = @env.fetch("PATH", "").split(File::PATH_SEPARATOR) +
        [File.join(@home, ".local/bin"), File.join(@home, ".bun/bin")] + @system_paths
      path = override || dirs.map { |dir| File.join(dir, id) }.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      result = { "id" => id, "name" => name, "path" => path, "version" => nil,
                 "status" => "missing", "authStatus" => "unknown", "capabilities" => {},
                 "remediation" => "Install #{name} on the Mac, then refresh." }
      return result if path.nil?

      probe = @probe
      checked = probe.nil? ? probe_version(path) : probe.call(path)
      unless checked[:ok] && checked[:version].is_a?(String) && checked[:version].match?(/\d+\.\d+/)
        return result.merge("status" => "broken", "remediation" => "Cannot run #{name} --version; check the executable path and its runtime on the Mac.")
      end

      implemented = CAPABILITIES.key?(id)
      result.merge("version" => checked[:version], "status" => implemented ? "ready" : "unsupported",
                   "remediation" => implemented ? nil : "This Relay build does not yet include the #{name} adapter.",
                   "capabilities" => implemented ? { "streaming" => true, "resume" => true, "stop" => true }.merge(CAPABILITIES.fetch(id)) : {})
    end

    # Keep output bounded, discard stderr (which may contain credential details),
    # and kill the entire probe process group on timeout, including broken shims.
    sig { params(path: String).returns(T::Hash[Symbol, T.untyped]) }
    def probe_version(path)
      result = T.let({ ok: false }, T::Hash[Symbol, T.untyped])
      Open3.popen2(@env, path, "--version", err: File::NULL, pgroup: true) do |stdin, stdout, child|
        stdin.close
        reader = Thread.new do
          output = stdout.read(512).to_s
          stdout.read(4096) until stdout.eof?
          output
        end
        begin
          Timeout.timeout(@timeout) do
            status = child.value
            result = { ok: status.success?, version: reader.value.to_s.lines.first.to_s.strip }
          end
        rescue Timeout::Error
          begin
            Process.kill("KILL", -child.pid)
          rescue Errno::ESRCH
            # The child may have exited just as its timeout fired.
          end
          result = { ok: false }
        ensure
          reader.join
        end
      end
      result
    rescue SystemCallError, IOError
      { ok: false }
    end
  end
end
