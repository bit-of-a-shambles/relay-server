# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/config"
require "tmpdir"

RSpec.describe RelayDaemon::Config do
  # ----- from_env: router_dir / router_command defaults -----

  describe ".from_env" do
    around do |example|
      saved = ENV.to_hash
      ENV.delete("RELAY_ROUTER_DIR")
      ENV.delete("RELAY_ROUTER_COMMAND")
      ENV.delete("RELAY_PUSH_RELAY_URL")
      ENV.delete("RELAY_PUSH_RELAY_TOKEN")
      ENV.delete("RELAY_PUSH_ENVIRONMENT")
      ENV.delete("RELAY_CLAUDE_STREAMING")
      ENV["RELAY_DAEMON_TOKEN"] = "t"
      example.run
      ENV.replace(saved)
    end

    it "defaults router_dir to the sibling router/ checkout" do
      config = described_class.from_env
      expect(config.router_dir).to eq(described_class::DEFAULT_ROUTER_DIR)
      expect(File.basename(config.router_dir)).to eq("router")
    end

    it "defaults router_command to npm run start" do
      expect(described_class.from_env.router_command).to eq(["npm", "run", "start"])
    end

    it "enables Claude streaming by default for legacy launch environments" do
      expect(described_class.from_env.claude_streaming).to be(true)

      ENV["RELAY_CLAUDE_STREAMING"] = "1"
      expect(described_class.from_env.claude_streaming).to be(true)

      ENV["RELAY_CLAUDE_STREAMING"] = "0"
      expect(described_class.from_env.claude_streaming).to be(false)
    end

    it "reads router_dir from RELAY_ROUTER_DIR" do
      ENV["RELAY_ROUTER_DIR"] = "/custom/router/path"
      expect(described_class.from_env.router_dir).to eq("/custom/router/path")
    end

    it "parses RELAY_ROUTER_COMMAND as a JSON array" do
      ENV["RELAY_ROUTER_COMMAND"] = '["node", "dist/index.js"]'
      expect(described_class.from_env.router_command).to eq(["node", "dist/index.js"])
    end

    it "parses RELAY_ROUTER_COMMAND as a shell-split string" do
      ENV["RELAY_ROUTER_COMMAND"] = "node dist/index.js --flag 'quoted value'"
      expect(described_class.from_env.router_command).to eq(
        ["node", "dist/index.js", "--flag", "quoted value"]
      )
    end

    it "treats a blank RELAY_ROUTER_COMMAND as unset" do
      ENV["RELAY_ROUTER_COMMAND"] = "   "
      expect(described_class.from_env.router_command).to eq(["npm", "run", "start"])
    end

    it "raises when RELAY_ROUTER_COMMAND starts with [ but is malformed JSON" do
      ENV["RELAY_ROUTER_COMMAND"] = "[not valid json"
      expect { described_class.from_env }.to raise_error(JSON::ParserError)
    end

    it "disables push forwarding when RELAY_PUSH_RELAY_URL is unset" do
      config = described_class.from_env
      expect(config.push_relay_url).to be_nil
      expect(config.push_relay_token).to be_nil
      expect(config.push_environment).to eq("production")
    end

    it "reads a valid paired push relay configuration" do
      ENV["RELAY_PUSH_RELAY_URL"] = "https://push.example.test/push"
      ENV["RELAY_PUSH_RELAY_TOKEN"] = "relay-secret"
      ENV["RELAY_PUSH_ENVIRONMENT"] = "sandbox"

      config = described_class.from_env
      expect(config.push_relay_url).to eq("https://push.example.test/push")
      expect(config.push_relay_token).to eq("relay-secret")
      expect(config.push_environment).to eq("sandbox")
    end

    it "rejects partial push relay configuration without exposing the token" do
      ENV["RELAY_PUSH_RELAY_URL"] = "https://push.example.test/push"
      expect { described_class.from_env }
        .to raise_error(ArgumentError, /RELAY_PUSH_RELAY_URL and RELAY_PUSH_RELAY_TOKEN/)

      ENV.delete("RELAY_PUSH_RELAY_URL")
      ENV["RELAY_PUSH_RELAY_TOKEN"] = "do-not-log-this"
      expect { described_class.from_env }
        .to raise_error(ArgumentError, /RELAY_PUSH_RELAY_URL and RELAY_PUSH_RELAY_TOKEN/)
      expect { described_class.from_env }.to raise_error do |error|
        expect(error.message).not_to include("do-not-log-this")
      end
    end

    it "rejects blank relay tokens and invalid relay URLs" do
      invalid_urls = [
        "http://push.example.test/push",
        "https:///push",
        "https://push.example.test/not-push",
        "https://push.example.test/push?debug=1",
        "https://push.example.test/push#fragment",
        "not a url",
        "https://user@push.example.test/push"
      ]

      invalid_urls.each do |url|
        ENV["RELAY_PUSH_RELAY_URL"] = url
        ENV["RELAY_PUSH_RELAY_TOKEN"] = "relay-secret"
        expect { described_class.from_env }.to raise_error(ArgumentError, /RELAY_PUSH_RELAY_URL/)
      end

      ENV["RELAY_PUSH_RELAY_URL"] = "https://push.example.test/push"
      ENV["RELAY_PUSH_RELAY_TOKEN"] = "   "
      expect { described_class.from_env }.to raise_error(ArgumentError, /RELAY_PUSH_RELAY_TOKEN/)
    end

    it "rejects unsupported push environments even when push is disabled" do
      ENV["RELAY_PUSH_ENVIRONMENT"] = "development"
      expect { described_class.from_env }
        .to raise_error(ArgumentError, /RELAY_PUSH_ENVIRONMENT must be production or sandbox/)
    end
  end

  # ----- router_command_from_env (direct) -----

  describe ".router_command_from_env" do
    it "returns the default for nil" do
      expect(described_class.router_command_from_env(nil)).to eq(["npm", "run", "start"])
    end
  end

  # ----- router_dir_missing_error -----

  describe "#router_dir_missing_error" do
    let(:base_attrs) do
      { daemon_token: "t", host: "127.0.0.1", port: 7777, db_path: "/tmp/relay_test.db" }
    end

    it "is nil when router_dir exists" do
      dir = Dir.mktmpdir
      config = described_class.new(**base_attrs, router_dir: dir)
      expect(config.router_dir_missing_error).to be_nil
    end

    it "names the missing path and RELAY_ROUTER_DIR when router_dir does not exist" do
      missing = File.join(Dir.mktmpdir, "does-not-exist")
      config = described_class.new(**base_attrs, router_dir: missing)
      error = config.router_dir_missing_error
      expect(error).to include(missing)
      expect(error).to include("RELAY_ROUTER_DIR")
    end
  end
end
