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

## Install

Homebrew installation is the intended distribution path once a tagged
release exists (see `docs/AGENT_PLAYBOOK.md` milestones M59-M61):

```bash
brew tap bit-of-a-shambles/relay
brew install relay
brew install --cask relay-menubar   # optional macOS menu-bar wrapper
```

Until a tap exists, run from source — see `router/README.md` and
`daemon/README.md` for install/run instructions.

To validate a release locally before publishing it, assemble a tarball without
creating a GitHub release. The script emits a literal local formula and a
literal tap formula, both pinned to that tarball's version and checksum:

```bash
scripts/release.sh --dry-run v0.1.0
brew tap-new --no-git relaydev/relay-acceptance
cp dist/releases/relay-local.rb "$(brew --repo relaydev/relay-acceptance)/Formula/relay.rb"
brew install --build-from-source relaydev/relay-acceptance/relay
brew test relaydev/relay-acceptance/relay
brew uninstall relaydev/relay-acceptance/relay
brew untap relaydev/relay-acceptance
```

The generated `dist/releases/relay.rb` is the formula artifact for the public
tap. `packaging/homebrew/relay.rb` is its renderable, style-checked template.

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
