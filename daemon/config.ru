# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "lib")

require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/llm_call_store"
require "relay_daemon/pairing_service"
require "relay_daemon/provider_store"
require "relay_daemon/push_device_store"
require "relay_daemon/push_notifier"
require "relay_daemon/repo_store"
require "relay_daemon/session_store"

config = RelayDaemon::Config.from_env
db     = RelayDaemon::Db.new(config.db_path)

RelayDaemon::App.set(:relay_config, config)
RelayDaemon::App.set(:stats_db, db)
RelayDaemon::App.set(:llm_call_store, RelayDaemon::LlmCallStore.new(db))
RelayDaemon::App.set(:repo_store, RelayDaemon::RepoStore.new(db))
RelayDaemon::App.set(:provider_store, RelayDaemon::ProviderStore.new(db))
RelayDaemon::App.set(:session_store, RelayDaemon::SessionStore.new(db))
RelayDaemon::App.set(:pairing_service, RelayDaemon::PairingService.new(db))
push_device_store = RelayDaemon::PushDeviceStore.new(db)
RelayDaemon::App.set(:push_device_store, push_device_store)
push_notifier = RelayDaemon::PushNotifier.new(
  relay_url: config.push_relay_url,
  relay_token: config.push_relay_token,
  environment: config.push_environment,
  device_store: push_device_store
)
RelayDaemon::App.set(:push_notifier, push_notifier)
at_exit { push_notifier.shutdown }

run RelayDaemon::App
