# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/approval_settings_store"
require "relay_daemon/db"
require "tmpdir"

RSpec.describe RelayDaemon::ApprovalSettingsStore do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db) { RelayDaemon::Db.new(db_path) }
  let(:store) { described_class.new(db) }

  after { db.connection.close }

  it "defaults to ask_on_sensitive" do
    expect(store.mode).to eq("ask_on_sensitive")
  end

  it "updates and persists the mode" do
    store.update_mode!("full_auto")
    expect(store.mode).to eq("full_auto")

    store.update_mode!("ask_every_time")
    expect(store.mode).to eq("ask_every_time")
  end

  it "rejects an invalid mode" do
    expect { store.update_mode!("nonsense") }.to raise_error(ArgumentError, /invalid approval mode/)
    expect(store.mode).to eq("ask_on_sensitive")
  end

  it "exposes the three valid modes as constants" do
    expect(described_class::MODES).to eq(%w[full_auto ask_on_sensitive ask_every_time])
    expect(described_class::FULL_AUTO).to eq("full_auto")
    expect(described_class::ASK_ON_SENSITIVE).to eq("ask_on_sensitive")
    expect(described_class::ASK_EVERY_TIME).to eq("ask_every_time")
    expect(described_class::DEFAULT_MODE).to eq("ask_on_sensitive")
  end
end
