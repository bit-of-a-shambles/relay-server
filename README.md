# Relay Server

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Relay is a cost-aware router and Mac-side daemon for running coding agents
(like Claude Code) against cheap models by default, falling back to frontier
models only when verified test outcomes say a task needs it.

This repository is the **open-core server side**: the TypeScript cost router
and the Ruby + Sorbet Mac daemon that a client talks to. Both are implemented
and tested with 100% enforced coverage. There is also an optional macOS
menu-bar wrapper for pairing and daemon lifecycle.

The iOS client app is closed-source and lives in a private companion
repository; it is not required to use the router or daemon directly (the
daemon exposes a plain REST/WebSocket API — see `daemon/README.md`).

## Components

```text
router/     TypeScript, Anthropic Messages API compatible cost router
daemon/     Ruby + Sorbet Mac-side service (SQLite, Git worktrees, pairing)
menubar/    Swift macOS status-item wrapper (optional, for daemon lifecycle)
```

## Install from source

The supported installation is the source checkout below. Requirements: Node.js
22+, Ruby 3.3+, Bundler, and at least one supported coding harness installed
and signed in on your Mac. A public Homebrew tap and notarized menu-bar
installer have not been released.

```bash
git clone https://github.com/bit-of-a-shambles/relay-server.git
cd relay-server/router
npm ci
npm run build
cd ../daemon
bundle install
bundle exec bin/daemon
```

The default loopback address is for local checks on the Mac. To connect an
iPhone, install Tailscale on both devices and start the daemon on the Mac's
Tailscale address instead:

```bash
RELAY_DAEMON_HOST="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 | head -n 1)" RELAY_DAEMON_PORT=17777 bundle exec bin/daemon
```

In another terminal, from the same `daemon/` directory:

```bash
RELAY_DAEMON_PORT=17777 bundle exec bin/daemon pair
```

Enter the printed URL and one-time code on the iPhone. Keep the Mac running
and reachable. A private LAN address also works on the same network; see
[daemon setup and configuration](daemon/README.md).

## Harnesses and model sources

Relay discovers Claude Code, Codex, Gemini CLI, GitHub Copilot CLI and Oh My Pi
on the Mac. Threads retain their selected harness, model source, model and
inference mode. Missing executables and unsupported combinations are reported
before execution. Existing CLI authentication stays with the CLI.

- OpenRouter uses `OPENROUTER_API_KEY` in the Mac daemon's environment.
- Ollama and LM Studio model discovery runs against the Mac's loopback
  endpoints; compatible harnesses can use those local sources.
- Doubleword supports compatible Codex Responses requests in realtime or
  async mode. Set `DOUBLEWORD_API_KEY` before starting the daemon, or save
  provider configuration through the client.
- Native providers use the selected harness's own authentication/configuration.
  Gemini uses native Google models in this release.
- Gemini and Oh My Pi require an explicit Full Auto selection. Other harnesses
  expose only their implemented approval modes. Review the permission choice
  before sending a request.

API keys and provider configuration remain on your Mac. The model provider
you choose may process prompts, code and tool output under its own terms.
Relay does not install the harnesses or provide model credits.

Oh My Pi 17.3.5 terminal events and newer settled-turn RPC formats are supported.
Provider errors retain useful status details with credentials redacted. Budget
failures stop immediately without retrying another model; OpenRouter budget
errors link to its credits settings.

## Release tooling

`scripts/release.sh --dry-run vX.Y.Z` builds a runtime tarball and checksummed
formula without publishing. The payload includes the daemon, permission hook,
harness bridge, and built router; development files and private client source
are excluded. The offline archive contract is `bash scripts/release_test.sh`.
A generated formula is a release artifact, not an already-published tap.

## Contributing

This project is built milestone-by-milestone from
[docs/AGENT_PLAYBOOK.md](docs/AGENT_PLAYBOOK.md), following the working
method in [AGENTS.md](AGENTS.md) ("The Loop"): one milestone, one commit,
tests and coverage gates green before moving on.

Validation gates (must pass before any PR is merged):

```bash
# router
cd router && npm ci && npm run build && npm test && npm run coverage

# daemon
cd daemon && bundle install && bundle exec srb tc && bundle exec rspec

# menubar (macOS only)
cd menubar && xcodegen generate && xcodebuild test -project RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS'
```

See [docs/STATUS.md](docs/STATUS.md) for current state and
[docs/PLAN.md](docs/PLAN.md) for the full architecture.

## License

MIT, see [LICENSE](LICENSE).
