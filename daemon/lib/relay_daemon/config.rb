# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

module RelayDaemon
  class Config < T::Struct
    extend T::Sig

    const :daemon_token, T.nilable(String)
    const :host, String
    const :port, Integer
    const :db_path, String
    const :worktrees_dir, String, default: File.expand_path("~/.relay/worktrees")
    const :agent_log_dir, String, default: File.expand_path("~/.relay/runs")
    const :agent_command, T.nilable(String), default: nil
    const :router_base_url, String, default: "http://127.0.0.1:7778/api"
    const :routing_config_path, T.nilable(String), default: nil

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
        routing_config_path: ENV["RELAY_ROUTING_CONFIG"]
      )
    end
  end
end
