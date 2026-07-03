# Status

Last updated: 2026-07-03 (repo split from the private monorepo).

This repository is the public, MIT-licensed extraction of the router +
daemon + menubar components from Relay's private monorepo (see
[docs/PLAN.md](PLAN.md) for architecture). The private monorepo retains full
history and the iOS client; this repo starts fresh at the split point rather
than carrying that history over, so this file begins here rather than as a
copy of the private repo's status log.

## Completed (carried into this repo working, tested, at 100% coverage)

- Router: Anthropic Messages API compatible cost router with tiered routing,
  quality-dial and per-message overrides, escalation-on-failure retries,
  named upstream provider support (`providerName::model-id`), and full call
  logging (JSONL + HTTP sink to the daemon).
- Daemon: pairing (QR + claim tokens), repo registration, chat-session
  lifecycle (create/message/diff/test/approve/discard) over isolated Git
  worktrees, SQLite persistence with per-thread connection safety, the
  outcome-verified eval dataset and routing-config writer, a model catalog
  endpoint, and a custom-provider store.
- Menubar: daemon lifecycle control (start/stop), QR-based pairing display,
  robust repo-root resolution regardless of launch method.

See `docs/AGENT_PLAYBOOK.md` for the exact milestones this state was built
from (numbering is inherited from the private monorepo's playbook; gaps are
private/iOS-only milestones that stayed in the private repo).

## Next recommended work

- M56 — Public repo CI (GitHub Actions).
- M57 — Daemon/router install-layout independence (Homebrew prerequisite).
- M58 — Menubar: installed-daemon discovery + real Settings.
- M59 — Release script + Homebrew formula.
- M60 — Menubar notarization script + cask.

## Blocked

Nothing blocked as of the split. M61 (first public release + brew
acceptance) is a user task pending M56-M60.
