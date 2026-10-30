# Status

Last updated: 2026-10-30.

This repository is the public, MIT-licensed extraction of Relay's router,
daemon, menubar companion, release tooling, site, and push relay. The private
repository retains the iOS client and full pre-split history.

## M98 — encrypted cloud relay deployed (2026-10-30)

The hosted Worker is live at
`wss://relay-encrypted-tunnel.relay-tunnel.workers.dev`. The Mac companion
connects outbound and defaults to that endpoint; setting `RELAY_TUNNEL_URL=`
disables cloud access, or a custom WSS origin enables self-hosting. Update the
iPhone companion and scan a new QR. Direct LAN/Tailscale stays preferred when
reachable; the Mac can otherwise stay bound to loopback. Keep it awake/online.

QR-authenticated ephemeral P-256 ECDH, HMAC/HKDF-SHA256 and ChaCha20-Poly1305
protect API/event contents. Only routing metadata and ciphertext reach the
Worker; bearer tokens and QR secrets remain between devices. Pending claims
expire; tokens remain revocable. Request limits, replay/tamper rejection,
reconnect and no automatic replay of uncertain writes are covered by tests.
The protocol has not had an independent cryptographic audit.

Validation: Worker build and 5 tests, 100% statements/branches/functions/lines;
daemon Sorbet and 535 specs, 100% lines; 47 Mac tests and build. Real internet
smokes verify Ruby peer pairing/API/events/reconnect/revocation without plaintext
markers, and the native Swift CryptoKit client against the live Ruby OpenSSL
bridge and running loopback-only Mac daemon. These are release smokes, separate
from the offline unit suites. Physical phone/cellular acceptance is not inferred
from these checks. See [the deployment runbook](../relay-tunnel/README.md).

Next: update/re-pair the iPhone app, verify cellular operation on the physical
phone, and retain the separate app-store/hardware acceptance workflow.

## Completed

- M124: Oh My Pi 17.3.5 terminal `agent_end` and newer settled-turn RPC
  completion now request state once and persist the native session, so a
  successful reply finishes and can be resumed. Provider failures preserve
  useful status details while redacting credentials. Budget errors stop
  immediately, with a trusted OpenRouter credits link where appropriate;
  HTTP 402 never retries another model.
- M124 validation: router build, 75 tests and 100% statements/branches/functions/
  lines; daemon Sorbet and 513 examples with 100% line coverage; offline release
  packaging and changed-source secret scans pass. Legacy/current completion,
  errors, budget stops and session lifecycle have regression fixtures. The
  pre-existing UTF-8 migration regression is preserved. No private client,
  signing material or release records are included.

- M117: current harness/provider execution APIs, all five native adapter
  fixtures, local/provider catalogs, exact per-thread execution choices,
  approvals, Doubleword async lifecycle and WebSocket readiness/recovery
  support are synchronized into the public runtime. Source installs include
  the required permission hook and harness bridge. Native CLI authentication
  remains on the user's Mac; no private mobile source or signing material
  is included.
- Public setup now uses a working source-install guide, including the actual
  Tailscale macOS binary path when no shell shim exists. Removed claims of an
  already-installable Homebrew tap. Added business email support and operator
  information to support/privacy/terms, and aligned Pro features with the app.
- Validation: router build and 74 tests, 100% statements/branches/functions/
  lines; Sorbet clean and 500 daemon tests, 100% lines; 46 menubar tests and
  macOS build; offline archive regression with runtime helpers and a verified
  checksum. The pre-existing UTF-8 migration fix and regression are preserved.
- Fresh source startup/pairing/discovery and token revocation passed on the
  Mac. Installed ready harnesses were Claude Code, Codex and Oh My Pi;
  Gemini's version probe reported broken and Copilot was missing. The RPC
  startup/state exchange for installed Oh My Pi was checked without model
  inference. Availability/sign-in still depends on the user's installation.
- The changed-file secret scan is clean. Full-tree scanning reports only the
  pre-existing PEM template built from a runtime-generated test key in
  `push-relay/test/push-relay.test.ts`; this exact unchanged expression has
  no embedded private key material. No scanner or coverage threshold changed.
- Landing/support content passed iPhone-width layout and link checks. The
  Pages workflow publishes changes merged into the default branch.

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
- M80: installed daemons generate private router call-record credentials and
  default routing/sink paths, expose effective capabilities, and permanently
  honor per-test routing-learning opt-outs.
- M81: explicit Relay Auto, named direct/OpenRouter managed targets, sticky
  OpenRouter sessions, and separate run/selected-target/actual-model
  attribution for streaming and non-streaming calls.

See `docs/AGENT_PLAYBOOK.md` for exact milestone contracts and validation.
Numbering is inherited from the private repository; gaps are private or
iOS-only milestones.

## Next Recommended Work

- Use the current default-branch source for App Review so client testing uses
  the completion and budget-error fixes above. Real iPhone purchase/restore,
  streamed-reply acceptance and a camera video of the iPhone interacting with
  the Mac remain physical checks; these automated results do not establish them.

- Use the source installation in README for the current runtime. Keep
  physical client purchase/restore/streaming acceptance separate from these
  Mac-side checks. A notarized installer and public Homebrew tap remain
  deferred; do not advertise them as available.
- M82: private seed evals and deterministic, budget-capped model admission;
  the private fixture corpus remains outside this public repository.
- M60: notarized menubar cask, blocked until a Developer ID Application
  certificate and private key are installed on the release Mac.
- M70: provision APNs/Cloudflare secrets and run the end-to-end push check
  after the private iOS M69 client is installed.

## Blocked

- M60 requires an Account Holder-provisioned Developer ID Application
  certificate. The release Mac currently has no such signing identity.
- M61 is the first public release and Homebrew acceptance user task after M60.
- M70 requires an Apple APNs auth key and an authenticated Cloudflare account.
