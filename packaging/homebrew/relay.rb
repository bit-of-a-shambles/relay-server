# typed: strict
# frozen_string_literal: true

# Homebrew formula template. scripts/release.sh renders literal source,
# version, and checksum values into this file for a tap or local acceptance.
class Relay < Formula
  desc "Cost-aware coding-agent router and Mac daemon"
  homepage "https://github.com/bit-of-a-shambles/relay-server"
  url "__RELAY_SOURCE_URL__"
  version "__RELAY_VERSION__"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # rendered by release.sh
  license "MIT"

  depends_on "node"
  depends_on "ruby" => ">= 3.3"

  def install
    ENV.prepend_path "PATH", formula_opt_bin("node")
    ENV.prepend_path "PATH", formula_opt_bin("ruby")

    libexec.install "VERSION", "daemon", "router"

    cd libexec / "daemon" do
      system "bundle", "config", "set", "--local", "deployment", "true"
      system "bundle", "config", "set", "--local", "without", "development:test"
      system "bundle", "install"
    end

    cd libexec / "router" do
      system "npm", "ci", "--omit=dev"
    end

    (bin / "relay-daemon").write <<~EOS
      #!/bin/bash
      set -euo pipefail
      export PATH="#{formula_opt_bin("ruby")}:#{formula_opt_bin("node")}:$PATH"
      export LANG="${LANG:-en_US.UTF-8}"
      export LC_ALL="${LC_ALL:-en_US.UTF-8}"
      export BUNDLE_GEMFILE="#{libexec}/daemon/Gemfile"
      export RELAY_ROUTER_DIR="#{libexec}/router"
      export RELAY_ROUTER_COMMAND="node dist/index.js"
      exec bundle exec "#{libexec}/daemon/bin/daemon" "$@"
    EOS
  end

  test do
    daemon_port = free_port
    router_port = free_port
    env = {
      "RELAY_DAEMON_HOST"   => "127.0.0.1",
      "RELAY_DAEMON_PORT"   => daemon_port.to_s,
      "RELAY_ROUTER_PORT"   => router_port.to_s,
      "RELAY_DB_PATH"       => (testpath / "relay.sqlite3").to_s,
      "RELAY_WORKTREES_DIR" => (testpath / "worktrees").to_s,
      "RELAY_AGENT_LOG_DIR" => (testpath / "runs").to_s,
    }
    pid = spawn env, bin / "relay-daemon"

    begin
      body = shell_output(
        "curl --fail --silent --show-error --retry 30 --retry-delay 1 --retry-connrefused " \
        "http://127.0.0.1:#{daemon_port}/healthz",
      )
      assert_match '"status":"ok"', body
    ensure
      Process.kill "TERM", pid
      Process.wait pid
    end
  end
end
