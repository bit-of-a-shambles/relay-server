# typed: true
# frozen_string_literal: true

require "json"
require "shellwords"
require "sorbet-runtime"

module RelayDaemon
  class Config < T::Struct
    extend T::Sig

    # Default location of the router checkout relative to this file, i.e.
    # <repo>/router when the daemon is run from a source checkout next to
    # `router/`. Installed (Homebrew) layouts override via RELAY_ROUTER_DIR.
    DEFAULT_ROUTER_DIR = T.let(File.expand_path("../../../router", __dir__), String)
    DEFAULT_ROUTER_COMMAND = T.let(["npm", "run", "start"], T::Array[String])

    const :daemon_token, T.nilable(String)
    const :host, String
    const :port, Integer
    const :db_path, String
    const :worktrees_dir, String, default: File.expand_path("~/.relay/worktrees")
    const :agent_log_dir, String, default: File.expand_path("~/.relay/runs")
    const :agent_command, T.nilable(String), default: nil
    const :router_base_url, String, default: "http://127.0.0.1:7778/api"
    const :routing_config_path, T.nilable(String), default: nil
    const :router_dir, String, default: DEFAULT_ROUTER_DIR
    const :router_command, T::Array[String], default: DEFAULT_ROUTER_COMMAND

    sig { returns(Config) }
    def self.from_env
      new(
        daemon_token: ENV["RELAY_DAEMON_TOKEN"],
        host: T.must(ENV.fetch("RELAY_DAEMON_HOST", "127.0.0.1")),
        port: ENV.fetch("RELAY_DAEMON_PORT", "7777").to_i,
        db_path: T.must(ENV.fetch("RELAY_DB_PATH", File.expand_path("~/.relay/relay.sqlite3"))),
        worktrees_dir: T.must(ENV.fetch("RELAY_WORKTREES_DIR", File.expand_path("~/.relay/worktrees"))),
        agent_log_dir: T.must(ENV.fetch("RELAY_AGENT_LOG_DIR", File.expand_path("~/.relay/runs"))),
        agent_command: ENV["RELAY_AGENT_COMMAND"],
        router_base_url: T.must(ENV.fetch("RELAY_ROUTER_BASE_URL", "http://127.0.0.1:7778/api")),
        routing_config_path: ENV["RELAY_ROUTING_CONFIG"],
        router_dir: T.must(ENV.fetch("RELAY_ROUTER_DIR", DEFAULT_ROUTER_DIR)),
        router_command: router_command_from_env(ENV["RELAY_ROUTER_COMMAND"])
      )
    end

    # Parses RELAY_ROUTER_COMMAND: a JSON array (e.g. '["node", "dist/index.js"]')
    # or a plain shell-style command line (e.g. "npm run start"). Falls back to
    # the default `npm run start` when unset.
    sig { params(raw: T.nilable(String)).returns(T::Array[String]) }
    def self.router_command_from_env(raw)
      return DEFAULT_ROUTER_COMMAND if raw.nil? || raw.strip.empty?

      stripped = raw.strip
      if stripped.start_with?("[")
        # A leading `[` always parses as a JSON array (or raises); a
        # non-array JSON value cannot start with `[`.
        T.cast(JSON.parse(stripped), T::Array[T.untyped]).map(&:to_s)
      else
        Shellwords.split(stripped)
      end
    end

    # Fail-fast check used by bin/daemon before starting the router
    # supervisor: nil when router_dir looks usable, otherwise a one-line
    # error message naming the offending path and the env var to fix it.
    sig { returns(T.nilable(String)) }
    def router_dir_missing_error
      return nil if File.directory?(router_dir)

      "daemon: router_dir #{router_dir} does not exist " \
        "(set RELAY_ROUTER_DIR to the router install location, or RELAY_SUPERVISE_ROUTER=0 to disable supervision)"
    end
  end
end
