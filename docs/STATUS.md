# Status

Last updated: 2026-07-13.

This repository is the public, MIT-licensed extraction of Relay's router,
daemon, menubar companion, release tooling, site, and push relay. The private
repository retains the iOS client and full pre-split history.

## Completed

- Router: Anthropic Messages API compatible cost router with tiered routing,
  named providers, verified escalation, and complete call attribution.
- Daemon: pairing, repository and chat-session lifecycle, Git worktrees,
  SQLite persistence, evaluation, model/provider configuration, and stats.
- Menubar: daemon lifecycle, QR pairing, installed-daemon discovery, and
  persisted launch settings.
- M56-M59: public CI, install-layout independence, menubar Settings, and the
  deterministic release tarball/Homebrew formula pipeline.
- M64: landing, privacy, support, and terms pages deployed through GitHub
  Pages using a real app capture.
- M67: authenticated, privacy-preserving APNs Worker with cached ES256 JWTs,
  bounded request/rate state, and outbound deadlines.
- M68: authenticated and idempotent device registration plus a bounded daemon
  push queue. Tokens are validated/canonicalized; delivery uses native HTTP
  timeouts within a monotonic event budget; failures never block daemon work.

See `docs/AGENT_PLAYBOOK.md` for exact milestone contracts and validation.
Numbering is inherited from the private repository; gaps are private or
iOS-only milestones.

## Next Recommended Work

- M60: notarized menubar cask, blocked until a Developer ID Application
  certificate and private key are installed on the release Mac.
- M70: provision APNs/Cloudflare secrets and run the end-to-end push check
  after the private iOS M69 client is installed.

## Blocked

- M60 requires an Account Holder-provisioned Developer ID Application
  certificate. The release Mac currently has no such signing identity.
- M61 is the first public release and Homebrew acceptance user task after M60.
- M70 requires an Apple APNs auth key and an authenticated Cloudflare account.
