# Status

Last updated: 2026-07-13.

This repository is the public, MIT-licensed extraction of the router +
daemon + menubar components from Relay's private monorepo (see
[docs/PLAN.md](PLAN.md) for architecture). The private monorepo retains full
history and the iOS client; this repo starts fresh at the split point rather
than carrying that history over.

## Completed

- Router: Anthropic Messages API compatible cost router with tiered routing,
  quality-dial and per-message overrides, escalation-on-failure retries,
  named upstream provider support (`providerName::model-id`), and full call
  logging (JSONL + HTTP sink to the daemon).
- Daemon: pairing, repository registration, chat-session lifecycle over
  isolated Git worktrees, SQLite persistence, outcome-verified evaluation,
  model catalog, and custom-provider storage.
- Menubar: daemon lifecycle control, QR pairing, installed-daemon discovery,
  and persisted launch settings.
- M56: public repository CI for router, daemon, and menubar.
- M57: daemon/router install-layout independence.
- M58: installed-daemon discovery and real menubar Settings.
- M59: deterministic release tarball/checksum/formula generation, a public
  Homebrew formula template, and local formula acceptance tooling.
- Push relay: authenticated, privacy-preserving APNs forwarding with cached
  ES256 JWTs, bounded request/rate limits, and outbound deadlines.

See `docs/AGENT_PLAYBOOK.md` for the exact milestones this state was built
from. Numbering is inherited from the private monorepo; gaps are private or
iOS-only milestones.

## Next Recommended Work

- M60: notarized menubar cask, blocked until a Developer ID Application
  certificate and private key are installed on the release Mac.
- M68: daemon device-token storage and push forwarding can proceed
  independently of M60.

## Blocked

- M60 requires an Account Holder-provisioned Developer ID Application
  certificate. The release Mac currently has no such signing identity.
- M61 is the first public release and Homebrew acceptance user task after M60.
