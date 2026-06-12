# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "lib")

require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/llm_call_store"
require "relay_daemon/pairing_service"
require "relay_daemon/repo_store"
require "relay_daemon/task_store"

config = RelayDaemon::Config.from_env
db     = RelayDaemon::Db.new(config.db_path)

RelayDaemon::App.set(:relay_config, config)
RelayDaemon::App.set(:stats_db, db)
RelayDaemon::App.set(:llm_call_store, RelayDaemon::LlmCallStore.new(db))
RelayDaemon::App.set(:repo_store, RelayDaemon::RepoStore.new(db))
RelayDaemon::App.set(:task_store, RelayDaemon::TaskStore.new(db))
RelayDaemon::App.set(:pairing_service, RelayDaemon::PairingService.new(db))

run RelayDaemon::App
