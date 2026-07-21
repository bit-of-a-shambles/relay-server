# Agent Playbook: Relay Server (router + daemon + menubar)

This is the milestone list for the router, daemon, and menubar components of
Relay. It is a **subset** extracted from the private monorepo's playbook at
the point the open-core split happened: milestone numbers are inherited
unchanged from that playbook, and gaps in the numbering are milestones that
touched the iOS client or App-Store/monetization process and stayed in the
private repo (see the private repo's `docs/OPEN_CORE_SPLIT.md` for the full
classification, if you have access to it). Do not renumber; a future
milestone in this repo continues after the highest number here.

Tracks A-C, most of Track D/E/F/G/H/I (the router/daemon/menubar-only
milestones) are complete. Track K's forward-looking public-repo milestones
(M56-M60: CI, install-layout independence, Homebrew distribution) and
Track M's push-relay milestones (M67-M68) are the current/next work.

**How to use this file:** follow The Loop in [AGENTS.md](../AGENTS.md).
One unchecked milestone at a time, in order. Each milestone below has a
**Goal**, explicit **Steps**, a **Done when** checklist, and the **Validate**
commands that must pass before you commit. Tick the milestone's checkbox in
this file as part of its commit.

Conventions used throughout:

- All daemon commands run from `daemon/`.
- All router commands run from `router/`.
- "Typed" means a Sorbet `T::Struct` or a class with `sig` signatures and
  `# typed: strict` where practical (`# typed: true` is acceptable for Sinatra
  route files).
- Every milestone must keep `bundle exec srb tc`, `bundle exec rspec` (with
  SimpleCov at 100% line coverage), and — if router code changed —
  `npm run coverage` green.
- Tests never hit the network and never use the real `claude` CLI; use fake
  scripts and fixtures.
- The macOS menubar milestone validate command is:
  `cd menubar && xcodegen generate && xcodebuild test -project RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS'`.
- Milestones titled `**User task:**` are not agent loop iterations — they need
  information, credentials, or product decisions only the user has. The agent
  stops there per AGENTS.md ("Stop conditions") and reports what the user
  needs to do instead of implementing anything.

---

## Track A — Daemon scaffold

### M1 — Daemon skeleton with health endpoint

- [x] M1 complete

**Goal:** a runnable Ruby 3.3+ Sinatra app in `daemon/` with Sorbet, RSpec,
and SimpleCov (100% line coverage) wired up, serving `GET /healthz`.

**Steps:**

1. Create `daemon/Gemfile` with: `sinatra`, `puma`, `rackup`,
   `sorbet-runtime`; groups `development, test`: `sorbet`, `rspec`,
   `rack-test`, `simplecov`. Pin `ruby ">= 3.3"`.
2. Run `bundle install`, then `bundle exec srb init`.
3. Create `daemon/lib/relay_daemon/app.rb`: a modular Sinatra app
   (`class RelayDaemon::App < Sinatra::Base`) with
   `GET /healthz` returning status 200 and JSON body
   `{"status":"ok","version":"0.1.0"}` with `Content-Type: application/json`.
4. Create `daemon/config.ru` that runs the app, and `daemon/bin/daemon`
   (executable) that starts it on host `127.0.0.1` port `7777` by default,
   overridable via `RELAY_DAEMON_HOST` / `RELAY_DAEMON_PORT`.
5. Create `daemon/spec/spec_helper.rb` that starts SimpleCov **before**
   requiring app code, with `SimpleCov.minimum_coverage 100` and coverage
   tracked over `lib/`.
6. Write `daemon/spec/app_spec.rb` using `rack-test` covering `/healthz`
   (status, content type, body) and a 404 for an unknown path.
7. Write `daemon/README.md` with exact install/run/test commands.

**Done when:**

- `bundle exec srb tc` passes.
- `bundle exec rspec` passes with SimpleCov reporting 100% line coverage and
  failing the run if coverage drops below 100.
- `bundle exec rackup -p 7777` (or `bin/daemon`) serves `/healthz` locally.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M2 — Bearer-token auth middleware

- [x] M2 complete

**Goal:** every endpoint except `/healthz` and (later) `/pair/*` requires
`Authorization: Bearer <token>`.

**Steps:**

1. Create a typed `RelayDaemon::Config` (`T::Struct`) loaded from environment
   variables: `RELAY_DAEMON_TOKEN` (required for auth-protected routes),
   `RELAY_DAEMON_HOST`, `RELAY_DAEMON_PORT`, `RELAY_DB_PATH` (used in M4).
2. Add an auth check (Sinatra `before` filter or Rack middleware) that:
   - allows `GET /healthz` and any path starting with `/pair/` without auth;
   - otherwise compares the bearer token to the configured token using a
     constant-time comparison (`Rack::Utils.secure_compare`);
   - returns 401 with JSON `{"error":"unauthorized"}` on missing/wrong token;
   - returns 500 with JSON `{"error":"daemon token not configured"}` if
     `RELAY_DAEMON_TOKEN` is unset and a protected route is hit.
3. Add a trivial protected route to prove it (e.g. `GET /whoami` returning
   `{"ok":true}`) — M7 will add real ones.
4. Tests: healthz without token (200), protected route without token (401),
   with wrong token (401), with right token (200), with token unconfigured
   (500).

**Done when:** all five auth behaviours above are tested and green.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M3 — Router process supervision

- [x] M3 complete

**Goal:** the daemon can start, monitor, restart, and stop the router process.

**Steps:**

1. Create typed `RelayDaemon::RouterSupervisor` with:
   - constructor taking the command to run (array of strings), env hash, and
     restart backoff schedule (default: 1s, 2s, 4s, then every 8s);
   - `start` — spawns the process (`Process.spawn`), records the pid;
   - `stop` — sends TERM, waits up to 5s, then KILL;
   - automatic restart with backoff when the process exits unexpectedly;
   - `status` — `:stopped`, `:running`, or `:restarting`.
2. The default command (used by `bin/daemon`, not by tests) is
   `["npm", "run", "start"]` with `cwd` set to the `router/` directory and env
   passing through `OPENROUTER_API_KEY` and `RELAY_*` variables.
3. Tests use a fake command, e.g. `["ruby", "-e", "sleep 60"]` for the happy
   path and `["ruby", "-e", "exit 1"]` for the restart path. Inject a fake
   sleeper/clock so backoff tests do not actually sleep.
4. Wire it into `bin/daemon`: start the supervisor before the HTTP server,
   stop it on INT/TERM. Keep `bin/daemon` thin enough that all logic lives in
   tested classes.

**Done when:** start/stop/restart/backoff/status are all unit-tested with fake
commands; no test sleeps for real or touches `router/`.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

## Track B — Persistence and stats

### M4 — SQLite schema and migrations

- [x] M4 complete

**Goal:** daemon-owned SQLite database with the data model from
[PLAN.md](PLAN.md).

**Steps:**

1. Add the `sqlite3` gem.
2. Create typed `RelayDaemon::Db` that opens the database at
   `RELAY_DB_PATH` (default `~/.relay/relay.sqlite3`, directory created if
   missing; tests must point it at a tmpdir) and runs migrations.
3. Migrations are numbered SQL files in `daemon/db/migrations/`, applied in
   order, tracked in a `schema_migrations` table. Migration 001 creates:
   - `repos(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, test_command TEXT, created_at TEXT NOT NULL)`
   - `tasks(id TEXT PRIMARY KEY, repo_id INTEGER NOT NULL REFERENCES repos(id), prompt TEXT NOT NULL, quality_dial INTEGER NOT NULL, status TEXT NOT NULL CHECK(status IN ('queued','running','needs_review','approved','rejected','failed')), branch TEXT NOT NULL, created_at TEXT NOT NULL, finished_at TEXT, tests_passed INTEGER, cost_usd REAL, frontier_cost_usd REAL)`
   - `llm_calls(id INTEGER PRIMARY KEY, task_id TEXT REFERENCES tasks(id), requested_model TEXT NOT NULL, routed_model TEXT NOT NULL, tier INTEGER NOT NULL, prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL, cost_usd REAL, frontier_cost_usd REAL NOT NULL, latency_ms INTEGER NOT NULL, escalation_reason TEXT, status TEXT NOT NULL, error_message TEXT, created_at TEXT NOT NULL)`
4. Tests: fresh database gets all tables; running migrations twice is a no-op;
   `RELAY_DB_PATH` is respected.

**Done when:** migrations are idempotent and fully tested against tmpdir
databases.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M5 — Call-record ingestion (daemon + router sink)

- [x] M5 complete

**Goal:** the router POSTs every per-attempt call record to the daemon, which
persists it into `llm_calls`. JSONL logging remains available as a fallback.

This milestone touches BOTH components. Router validation commands apply.

**Daemon steps:**

1. Add `POST /internal/llm-calls` (auth required). Body is one JSON object
   exactly matching the router's `LlmCallRecord` type
   (`router/src/call-log.ts`), camelCase keys:
   `requestedModel, routedModel, tier, promptTokens, completionTokens,
   costUsd, frontierCostUsd, latencyMs, escalationReason, status,
   errorMessage, createdAt`, plus optional `taskId`.
2. Validate the body (reject with 422 + error JSON listing missing/invalid
   fields), insert a row into `llm_calls`, return 201 with `{"id": <row id>}`.
3. Tests: valid insert, missing field 422, non-JSON body 400, unauthorized 401.

**Router steps:**

4. Add `HttpCallLogSink` to `router/src/call-log.ts`: constructor takes
   `url` and `token`; `record()` POSTs the record as JSON with
   `Authorization: Bearer <token>`, swallowing (but `console.error`-logging)
   network errors so a dead daemon never breaks proxying.
5. Extend sink creation so that:
   - `RELAY_LLM_CALL_SINK_URL` (+ optional `RELAY_LLM_CALL_SINK_TOKEN`) creates
     an `HttpCallLogSink`;
   - `RELAY_LLM_CALL_LOG` still creates the JSONL sink;
   - both set means both sinks receive every record (add a fan-out sink).
6. Update `router/.env.example` and `router/README.md` with the new variables.
7. Router tests: cover `HttpCallLogSink` (happy path + network error
   swallowed) with a mocked `fetch`, the fan-out, and the env wiring.
   `npm run coverage` must stay at 100%.

**Done when:** a record posted by the router sink appears as an `llm_calls`
row in a daemon test database, both test suites are green, and router coverage
is still 100%.

**Validate:**
`bundle exec srb tc && bundle exec rspec` and
`npm run build && npm test && npm run coverage`

---

### M6 — `/stats` endpoint

- [x] M6 complete

**Goal:** `GET /stats?range=30d` aggregates persisted calls and tasks.

**Steps:**

1. Add `GET /stats` (auth required). Query param `range` accepts `7d`, `30d`
   (default), `90d`, `all`; anything else → 422.
2. Response JSON:

   ```json
   {
     "range": "30d",
     "spendUsd": 0.0,
     "frontierCostUsd": 0.0,
     "savedUsd": 0.0,
     "taskCount": 0,
     "taskSuccessRate": null,
     "perModel": [
       { "model": "moonshotai/kimi-k2", "calls": 0, "spendUsd": 0.0, "promptTokens": 0, "completionTokens": 0 }
     ]
   }
   ```

   `savedUsd = frontierCostUsd - spendUsd`. `taskSuccessRate` is
   approved-tasks ÷ finished-tasks, `null` when there are no finished tasks.
   Treat `cost_usd IS NULL` rows as 0 spend.
3. Implement aggregation in a typed `RelayDaemon::Stats` class with SQL doing
   the heavy lifting; filter by `created_at` against the range.
4. Tests: empty database, calls across multiple models, range filtering
   (insert rows with old `created_at`), invalid range, unauthorized.

**Done when:** Phase 2 acceptance from PLAN.md is reachable: `llm_calls` rows
from ≥2 routed models produce a `/stats` response with nonzero `savedUsd`
(prove it in a test).

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

## Track C — Task lifecycle

### M7 — Repos API

- [x] M7 complete

**Goal:** register and list repositories.

**Steps:**

1. `POST /repos` body `{"path": "...", "testCommand": "npm test"}`
   (testCommand optional). Validate: path exists, is a directory, and is a git
   repo (`.git` present or `git -C <path> rev-parse --git-dir` succeeds).
   `name` defaults to the directory basename. Duplicate path → 409.
   Success → 201 with the full repo object `{id, path, name, testCommand}`.
2. `GET /repos` → array of repo objects.
3. Build git interaction as a typed `RelayDaemon::Git` wrapper around
   `Open3.capture3` from the start — later milestones reuse it. No shelling
   out via backticks; always pass argument arrays (never interpolate into a
   shell string).
4. Tests create throwaway git repos in tmpdirs (`git init`). Cover: success,
   missing path, non-git dir, duplicate, list, unauthorized.

**Done when:** all cases above are tested and green.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M8 — Task creation, scratch branch, agent spawn

- [x] M8 complete

**Goal:** `POST /tasks` creates a task row, an isolated scratch worktree on
branch `relay/<task-id>`, and spawns the agent process.

**Steps:**

1. `POST /tasks` body `{"repoId": 1, "prompt": "...", "qualityDial": 5}`.
   Validate repoId exists and `qualityDial` is an integer 0–10. Task id is a
   UUID. Insert a `tasks` row with status `queued`.
2. Create the workspace with `git worktree add <repo>/.relay/worktrees/<task-id> -b relay/<task-id>`
   from the repo's current HEAD. Never check out branches in the user's own
   working directory. Add `.relay/` to the daemon's own bookkeeping, not the
   user's repo (`git worktree` paths can live outside the repo: prefer
   `~/.relay/worktrees/<task-id>`).
3. Spawn the agent inside the worktree. The command comes from
   `RELAY_AGENT_COMMAND` (a template; `{prompt}` is replaced with the task
   prompt, passed as a single argv element — no shell). The production default
   is the Claude Code CLI in headless mode (check `claude --help` for current
   flags before hardcoding; record what you used in daemon/README.md), with
   env `ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api` and a dummy
   `ANTHROPIC_API_KEY`. **Tests always set `RELAY_AGENT_COMMAND` to a fake
   script** (e.g. a ruby one-liner that writes a file in the worktree and
   exits 0).
4. Status transitions: `queued` → `running` when the process starts. Capture
   the agent's stdout/stderr to a per-task log file under
   `~/.relay/tasks/<task-id>/agent.log` (path configurable for tests).
5. `GET /tasks/:id` → `{"id", "repoId", "status", "branch", "prompt",
   "qualityDial", "createdAt", "finishedAt", "testsPassed", "costUsd",
   "savedUsd"}` (cost fields null until M10+ aggregates them).
6. Tests: task creation creates the row, the branch, and the worktree; agent
   fake runs in the worktree; invalid repoId 422; bad dial 422; unknown task
   404.

**Done when:** a task created against a tmpdir git repo runs a fake agent to
completion in an isolated worktree, observable via `GET /tasks/:id`.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M9 — Diff endpoint

- [x] M9 complete

**Goal:** `GET /tasks/:id/diff` exposes per-file diffs of the scratch branch.

**Steps:**

1. Compute `git diff --numstat <base>...relay/<task-id>` and
   `git diff <base>...relay/<task-id>` (base = the commit the worktree was
   created from; store it on the task row at M8 — add a migration adding a
   `base_commit` column if you did not already).
   Uncommitted changes left by the agent in the worktree must be committed
   first (auto-commit on agent exit with message `relay: task <id> result`) —
   add that to the M8 lifecycle as part of this milestone if missing.
2. Response: `[{"file": "a.rb", "unifiedDiff": "...", "additions": 3,
   "deletions": 1}]`. Empty array when the agent changed nothing.
3. Tests: fake agent edits one file and adds another; diff lists both with
   correct counts; empty diff case; 404 unknown task; unauthorized.

**Done when:** diffs round-trip correctly for edit/add/none cases.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M10 — Test runner and status transitions

- [x] M10 complete

**Goal:** after the agent exits, run the repo's `testCommand` in the worktree
and move the task to `needs_review` or `failed`.

**Steps:**

1. On agent exit: auto-commit (from M9), then if the repo has a
   `testCommand`, run it in the worktree (again via the argv-array runner,
   using `["sh", "-c", testCommand]` is acceptable here since the user
   configured the command), capture output to the task log, set
   `tests_passed` (1/0).
2. Status transitions: agent exit code 0 → `needs_review` (regardless of
   tests; `tests_passed` carries the signal). Agent nonzero exit → `failed`.
   Set `finished_at`.
3. Aggregate the task's `cost_usd` / `frontier_cost_usd` from `llm_calls`
   rows with this `task_id` at finish time. (Router → daemon task
   attribution: pass the task id to the agent env as `RELAY_TASK_ID` and
   forward it through the router sink — add the optional passthrough on the
   router side only if it is cheap; otherwise leave costs null and note it in
   STATUS.md as a known gap.)
4. Tests: passing test command → `needs_review` + `tests_passed: true`;
   failing test command → `needs_review` + `tests_passed: false`; agent
   crash → `failed`; no testCommand → `tests_passed: null`.

**Done when:** all four transition cases are tested and green.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M11 — Approve / reject

- [x] M11 complete

**Goal:** human-in-the-loop completion of a task.

**Steps:**

1. `POST /tasks/:id/approve` — only valid from `needs_review` (else 409).
   Merge `relay/<task-id>` into the branch that was checked out at task
   creation (record it at M8 — migration if needed): fast-forward when
   possible, merge commit otherwise. On merge conflict → 409 with
   `{"error":"merge_conflict"}` and the task stays `needs_review`. On
   success: status `approved`, remove the worktree, keep the branch.
2. `POST /tasks/:id/reject` — valid from `needs_review` or `failed` (else
   409). Remove the worktree and delete branch `relay/<task-id>`. Status
   `rejected`.
3. Never modify the user's checked-out working tree except via the merge in
   approve. Never force-delete anything outside `relay/<task-id>` branches
   and `~/.relay/` paths.
4. Tests: approve fast-forward, approve with merge commit (make a divergent
   commit on the base branch first), approve conflict, reject, wrong-state
   409s, 404, unauthorized.

**Done when:** Phase 3 acceptance's approve/reject legs work end-to-end in
tests against tmpdir repos.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M12 — WebSocket events

- [x] M12 complete

**Goal:** `WS /ws?token=...` pushes live task events.

**Steps:**

1. Add `faye-websocket` (with puma). If it proves incompatible, stop and
   record the blocker per AGENTS.md rather than switching servers silently.
2. Auth: `?token=` must match the daemon token; otherwise close immediately
   with code 4401.
3. Implement a typed in-process `RelayDaemon::EventBus` (subscribe /
   publish). Lifecycle code from M8–M11 publishes:
   `task.started`, `agent.event` (one per line of agent stdout for MVP),
   `task.needs_review`, `task.finished` (covers approved/rejected/failed,
   with the final status in the payload), `stats.updated` (after each task
   finish). Every frame: `{"type": "...", "taskId": "...", "payload": {...}}`.
4. Test the EventBus and the lifecycle publications directly (unit level).
   For the socket itself, one integration-style test with a real client
   connection if feasible; otherwise test the handler functions with fakes
   and note the manual `wscat` verification step in daemon/README.md.

**Done when:** all five event types are published by the lifecycle and
delivered to a subscriber in tests.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M13 — Pairing flow

- [x] M13 complete

**Goal:** replace the single static token with proper pairing.

**Steps:**

1. Migration: `auth_tokens(id INTEGER PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, label TEXT, created_at TEXT NOT NULL, revoked_at TEXT)`.
2. `POST /pair/start` (no auth; only allowed from localhost — check
   `Rack::Request#ip`): generates a single-use 6+ char pairing code expiring
   in 5 minutes, returns `{"qrPayload": {"url": "http://<host>:7777", "pairingCode": "..."}}`,
   and `bin/daemon pair` prints it as a terminal QR (add a tiny QR gem or
   print the code itself if QR rendering is heavy — note the choice in
   README).
3. `POST /pair/claim` body `{"pairingCode": "..."}`: valid+unexpired+unused →
   generate a 256-bit random token (`SecureRandom.hex(32)`), store its
   SHA-256 hash, return `{"authToken": "..."}` once. Reuse/expired/unknown →
   401.
4. Auth middleware (M2) now accepts EITHER `RELAY_DAEMON_TOKEN` (kept for
   tests/dev) or any unrevoked token in `auth_tokens` (compare hashes).
5. `bin/daemon revoke <token-prefix>` CLI sets `revoked_at`.
6. Bind safety: `bin/daemon` refuses to start when host is not a loopback or
   RFC1918/Tailscale (100.64/10) address unless `--unsafe` is passed.
7. Tests: claim happy path, single-use enforcement, expiry (inject clock),
   revocation, non-localhost `/pair/start` rejection, bind refusal logic.

**Done when:** a client can pair and use its token; revocation works; all
cases tested.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M14 — Phase 3 acceptance run + docs

- [x] M14 complete

**Goal:** prove the full lifecycle with `curl` + `wscat` alone, and bring all
docs up to date.

**Steps:**

1. Write `daemon/README.md` "Acceptance walkthrough": exact commands to
   start the daemon, pair, register a sample repo, create a task (with the
   fake agent via `RELAY_AGENT_COMMAND` if no `OPENROUTER_API_KEY` is
   available, with real Claude Code if it is), watch `/ws` with `wscat`,
   fetch the diff, approve, and see `/stats` update.
2. Actually run the walkthrough in your environment with the fake agent and
   paste the (trimmed) transcript into the README.
3. Update `docs/STATUS.md`: reflect the current component state and
   "Next recommended work" (this is a pattern to follow — update this repo's
   own `docs/STATUS.md`, not any other repo's).
4. Update the top-level `README.md` current-state paragraph.

**Done when:** the walkthrough transcript in daemon/README.md shows
create → events → diff → approve working end-to-end, and STATUS.md reflects
reality.

**Validate:** `bundle exec srb tc && bundle exec rspec` plus the manual
walkthrough.

---

## Track D — Post-M14 mobile pairing hardening (public subset)

The full track also added iOS-side pairing UI (private repo). Only the
daemon/menubar-side milestones are listed here.

### M16 — Tailscale-ready pairing start policy

- [x] M16 complete

**Goal:** pairing bootstrap works for real-device testing over private/Tailscale
networks while preserving safety.

**Steps:**

1. Update `/pair/start` request-source policy to allow loopback + RFC1918 +
   Tailscale source addresses.
2. Keep auth token claim semantics unchanged (single-use, 5-minute expiry).
3. Extend pairing specs for accepted/rejected source ranges.

**Done when:** a client on Tailscale/private LAN can start pairing and tests
cover the source policy.

**Validate:** `cd daemon && bundle exec srb tc && bundle exec rspec`

---

### M17 — Menubar QR robustness + docs refresh

- [x] M17 complete

**Goal:** menubar QR display and docs are robust for day-to-day testing.

**Steps:**

1. Harden menubar QR rendering/error handling and pairing payload validation.
2. Add menubar tests for malformed payload handling.
3. Update docs (`README.md`, `daemon/README.md`, `docs/STATUS.md`) with a
   tested Tailscale pairing walkthrough.

**Done when:** QR is consistently visible in menubar pairing alert, tests are
green, and docs describe the tested device flow.

**Validate:**
`cd menubar && xcodebuild test -scheme RelayMenuBar -destination 'platform=macOS'`

---

## Track E — Connect over Tailscale + cost-routed agents (public subset)

Added after the M15-M19 pairing-hardening track to make the daemon actually
bind reachably and run cost-routed agent tasks. One commit per milestone,
same gates. (M22, iOS build-number/TestFlight, stayed in the private repo.)

### M20 — Daemon launch correctness (router cwd + dual-bind)

- [x] M20 complete

**Goal:** the supervised router actually starts, and a Tailscale-bound daemon
stays reachable on loopback.

**Steps:**

1. `RouterSupervisor` accepts an optional `cwd:` and spawns the router with
   `Process.spawn(..., chdir: cwd)` when set, so `npm run start` runs in
   `router/` (where `dotenv/config` loads `router/.env`) instead of `daemon/`,
   where it crash-looped on a missing `package.json`.
2. `bin/daemon` passes `cwd: router_dir`, and binds every host from
   `BindSafety.bind_targets(config.host)` (`[host, "127.0.0.1"].uniq`) with one
   `--bind tcp://<host>:<port>` each, so loopback clients (router call-log sink,
   `bin/daemon pair`) work even when the daemon is bound to a Tailscale IP.

**Done when:** `RouterSupervisor` cwd and `BindSafety.bind_targets` are unit
tested, `bundle exec srb tc` is clean, and `bundle exec rspec` is green at 100%
line + branch coverage.

**Validate:** `bundle exec srb tc && bundle exec rspec`

### M21 — Menu bar launches the daemon for cost-routed agents

- [x] M21 complete

**Goal:** the menu bar starts the daemon so a client can reach it over
Tailscale and created sessions run Claude Code routed through the local router.

**Steps:**

1. `DaemonController.daemonCommand` launches `bundle exec ruby bin/daemon`
   (not `rackup`, which ignores `RELAY_DAEMON_HOST` and binds loopback only),
   keeping `RELAY_DAEMON_HOST`/`RELAY_DAEMON_PORT`.
2. The launch env adds `RELAY_AGENT_COMMAND` (Claude Code headless) and
   `ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api` + a dummy `ANTHROPIC_API_KEY`,
   which the spawned agent inherits, so its LLM calls hit the local router.
3. `DaemonControllerTests` asserts the new launch shape.

**Done when:** `xcodebuild test` for `RelayMenuBar` passes on macOS.

**Validate:** `cd menubar && xcodegen generate && xcodebuild test -project
RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS'`

### M23 — Menu bar resolves the repo root regardless of launch method

- [x] M23 complete

**Goal:** "Start Relay Daemon" works whether the app is launched from a terminal
or double-clicked in Finder.

**Problem:** `repoRootPath()` derived the repo from
`FileManager.currentDirectoryPath`, which is `/` for a Finder/`open` launch, so
the daemon command became `cd /daemon && …` and failed.

**Steps:**

1. Replace it with a pure, tested `resolveRepoRoot(envRoot:cwd:sourcePath:exists:)`
   that tries, in order: `RELAY_REPO_ROOT`, the working directory (parent when it
   ends in `/menubar`), then a bounded walk up from `#filePath` — validating each
   candidate by the existence of `daemon/bin/daemon`. `#filePath` points into the
   checkout the app was built from, so double-click (cwd `/`) resolves correctly.
2. Unit-test all four resolution branches.

**Done when:** `xcodebuild test` for `RelayMenuBar` passes (13 tests), and the
Release binary has the source path baked in so the walk-up resolves at runtime.

**Validate:** `cd menubar && xcodegen generate && xcodebuild test -project
RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS'`

---

## Track F — The moat: outcome-verified routing + the eval dataset (public subset)

The orchestrator is the product, not the agent CLI. These milestones make every
model call attributable to a test outcome, accumulate the
`(model × task → tests-passed)` dataset, and route by it. (M27, the iOS
savings dashboard, stayed in the private repo.)

### M24 — Per-task call attribution

- [x] M24 complete

**Goal:** every `llm_calls` row is joined to the task whose tests verify it
(closes the `task_id`-null gap that blocked the whole dataset).

**Steps:**

1. Router accepts `POST /api/task/:taskId/v1/messages` (in addition to
   `/api/v1/messages`), parses `:taskId` from the path, and stamps it on every
   `LlmCallRecord` (`router/src/server.ts`, `call-log.ts`).
2. Daemon sets per-task `agent_env["ANTHROPIC_BASE_URL"] =
   "#{router_base_url}/task/#{task_id}"` (new `Config#router_base_url`,
   default `http://127.0.0.1:7778/api`); the spawned agent's calls carry the id.
3. The daemon's `/internal/llm-calls` already persists `taskId` → `task_id`.

**Done when:** a routed call lands in `llm_calls` with the correct `task_id`;
router `npm run coverage` 100%; daemon `srb tc` + `rspec` 100%.

**Validate:**
`cd router && npm run build && npm test && npm run coverage` and
`cd daemon && bundle exec srb tc && bundle exec rspec`

### M25 — The eval dataset

- [x] M25 complete

**Goal:** a queryable `(model × task → tests-passed)` dataset — the proprietary
asset — built by joining every attributed call to the task whose tests verify it.

**Steps:**

1. Migration `005_eval_dataset_view.sql` creates the `eval_dataset` view:
   `llm_calls JOIN tasks JOIN repos` (inner joins, so only test-attributable
   calls appear), exposing call fields + task features (repo, prompt, quality
   dial) + the `tests_passed` label.
2. Typed `RelayDaemon::EvalStore#model_outcomes` rolls the view up per routed
   model: calls, distinct tasks, tasks-with-tests, tasks-passed, `passRate`
   (over distinct tasks that ran tests; nil when none), spend.
3. `GET /eval/model-outcomes` (auth) exposes the rollup for routing + the
   dashboard.

**Done when:** the rollup's pass-rate math, nil-when-untested case, and
not-attributed-call exclusion are tested; daemon `srb tc` + `rspec` 100%.

**Validate:** `cd daemon && bundle exec srb tc && bundle exec rspec`

### M26 — Outcome-verified routing loop

- [x] M26 complete

**Goal:** routing learns from test outcomes — the router prefers the cheapest
model that has actually been passing tests, not blind prompt heuristics.

**Steps:**

1. `RelayDaemon::RoutingConfigWriter` turns `EvalStore#model_outcomes` into a
   router-schema config, reordering each tier's models by measured pass rate
   (only models with ≥ `MIN_SAMPLES` test-verified tasks steer the order).
   `write!` atomically writes JSON to `RELAY_ROUTING_CONFIG`.
2. `Config#routing_config_path` (from `RELAY_ROUTING_CONFIG`, shared with the
   router). After each task finishes, `TaskRunner` recomputes and writes it, so
   the router hot-reloads improved ordering.
3. Router: `createRoutingConfigLoader` falls back to `DEFAULT_ROUTING_CONFIG`
   when the file does not exist yet (no 500s before the first write).

**Done when:** reorder/threshold/no-data/no-result cases are unit-tested, the
write-after-finish wire-in is tested, router `npm run coverage` 100%, daemon
`srb tc` + `rspec` 100%.

**Validate:**
`cd router && npm run build && npm test && npm run coverage` and
`cd daemon && bundle exec srb tc && bundle exec rspec`

---

## Track G — Chat-session architecture pivot (public subset)

The product direction changed: Relay is a **remote chat UI for a local Mac
coding agent**, closer to Codex, not a "create task → wait → review → done"
tool. The core primitive moves from `tasks` (one-shot, terminal status) to
**chat sessions + messages + local workspace state**, with diff/test/approve
as session actions a user can invoke repeatedly, at any point, rather than a
fixed end-of-task lifecycle. (M33, the iOS chat timeline, stayed in the
private repo; M34 below is trimmed to its daemon/router-side scope — the
private repo's copy also removed matching iOS task-only views.)

### M28 — Document the chat-session architecture pivot

- [x] M28 complete

**Goal:** capture the new product direction in the docs before any
implementation starts, per AGENTS.md ("do not invent new implementation work
without adding milestones first").

**Steps:**

1. Rewrite the architecture description in `docs/PLAN.md` to describe Relay
   as a remote chat UI for a local Mac coding agent (continuous sessions,
   resumed agent context, session-scoped diff/test/approve actions),
   superseding the original one-shot task model while keeping that original
   spec intact below it as historical reference until the migration lands.
2. Add an "Architecture pivot" section to `docs/STATUS.md` summarizing what
   changes, clarifying that the current task-based implementation still works
   end-to-end and is not being discarded outright, and pointing at Track G.
3. Add this track (M28-M34) to `docs/AGENT_PLAYBOOK.md` with one milestone per
   migration step: data model, resumable agent process, REST/WS contract,
   routing/eval attribution, chat timeline, and retiring the old surface.

**Done when:** `docs/PLAN.md`, `docs/STATUS.md`, and `docs/AGENT_PLAYBOOK.md`
consistently describe the chat-session direction and the concrete migration
milestones, with no implementation changed yet.

**Validate:** review `docs/PLAN.md`, `docs/STATUS.md`, and
`docs/AGENT_PLAYBOOK.md` for internal consistency; no test suite covers
prose docs, so this milestone has no automated validate command.

---

### M29 — Session + message data model

- [x] M29 complete

**Goal:** a `chat_sessions` + `messages` schema that can represent an
ongoing conversation scoped to a repo, alongside (not yet replacing) the
existing `tasks` table.

**Steps:**

1. Migration: `chat_sessions(id TEXT PRIMARY KEY, repo_id INTEGER NOT NULL
   REFERENCES repos(id), branch TEXT NOT NULL, base_commit TEXT NOT NULL,
   status TEXT NOT NULL CHECK(status IN ('active','archived')), created_at
   TEXT NOT NULL, last_message_at TEXT)`. One worktree/branch is created per
   session (reuse `RelayDaemon::Git`/the worktree path scheme from M8), not
   per message.
2. Migration: `messages(id TEXT PRIMARY KEY, session_id TEXT NOT NULL
   REFERENCES chat_sessions(id), role TEXT NOT NULL CHECK(role IN
   ('user','assistant','tool','system')), content TEXT NOT NULL, created_at
   TEXT NOT NULL, agent_run_id TEXT)`. `agent_run_id` ties a message to the
   underlying agent process invocation that produced it (M30).
3. Typed `RelayDaemon::SessionStore` / `MessageStore` (mirror the shape of
   `RepoStore`/`TaskStore`): create session, append message, list messages
   for a session ordered by `created_at`.
4. Do **not** remove `tasks`/`task_store.rb`/`llm_calls.task_id` yet — later
   milestones migrate call attribution and remove the old tables once
   nothing depends on them.
5. Tests: session creation creates the row + worktree/branch exactly once;
   message append/list ordering; foreign-key/not-found cases.

**Done when:** sessions and messages persist and round-trip in tests, with
no behavior change yet to `/tasks`.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M30 — Resumable agent process per session

- [x] M30 complete

**Goal:** a session's agent process retains conversation context across
multiple user messages, instead of M8's one-process-per-task model.

**Steps:**

1. Establish how the configured agent CLI resumes a conversation (Claude
   Code has session-resume flags — check `claude --help` for the current
   ones, e.g. a session id you can pass back in on the next invocation; do
   not assume the exact flag name without checking). Record the chosen
   mechanism in `daemon/README.md`.
2. `RelayDaemon::SessionRunner` (new, alongside `TaskRunner`): given a
   session id and a new user message, spawns/resumes the agent process in
   the session's worktree, passing prior context per the mechanism from
   step 1, and appends the user message row before spawning.
3. Capture stdout/stderr per agent run the same way M8 did per task
   (`~/.relay/sessions/<session-id>/runs/<run-id>.log`), and append an
   `assistant`/`tool` message row (or rows) once the run completes,
   tagged with `agent_run_id`.
4. **Tests always set `RELAY_AGENT_COMMAND` to a fake script** per the
   existing convention (M8) — extend the fake to accept and echo back a
   resume token so the resume contract is testable without the network or
   the real CLI.
5. Tests: first message spawns fresh; second message in the same session
   resumes with prior context observable (fake script proves it received the
   resume token); concurrent messages to the same session are serialized,
   not run in parallel.

**Done when:** two sequential fake-agent messages in one session prove
context carried over, and concurrent-message serialization is tested.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M31 — Session REST/WS contract

- [x] M31 complete

**Goal:** replace the task-creation contract with a session/message contract
a client can drive.

**Steps:**

1. `POST /sessions` body `{"repoId": 1}` → creates (or, if an `active`
   session already exists for that repo, returns) the session: `{id, repoId,
   branch, status, createdAt, lastMessageAt}`. One active session per repo
   is enough for the MVP; document that constraint.
2. `GET /sessions/:id/messages` → ordered message list.
3. `POST /sessions/:id/messages` body `{"content": "..."}` → appends the user
   message, invokes `SessionRunner` (M30), returns `202` with the created
   message id; the assistant's reply streams over WS (next step), it is not
   returned synchronously.
4. WS: extend `EventBus`/`ws_handler.rb` with `message.created`,
   `agent.event` (now session-scoped, not task-scoped), `session.updated`.
   Keep the existing task event types working unchanged for back-compat
   until M34 removes the old routes.
5. `GET /sessions/:id/diff` and `POST /sessions/:id/test` — same semantics
   as the old `/tasks/:id/diff` and the M10 test runner, but callable at any
   time against the session's current worktree state (not just once at
   end-of-task), and `POST /sessions/:id/approve` merges the session branch
   the same way M11 did for tasks, leaving the session `active` (not
   terminal) so the user can keep chatting and approve again later.
6. Tests: full REST surface against tmpdir repos with the fake agent;
   unauthorized/404/wrong-state cases mirroring M7-M11's coverage.

**Done when:** a session can be created, messaged twice, diffed, tested, and
approved entirely via the new routes in tests, with the old `/tasks/*` routes
still passing their existing specs unmodified.

**Validate:** `bundle exec srb tc && bundle exec rspec`

---

### M32 — Router/eval attribution moves to sessions

- [x] M32 complete

**Goal:** outcome-verified routing (Track F) keeps working under the new
primitive: every `llm_calls` row attributes to a session (and ideally the
message/run that produced it), not a terminal task.

**Steps:**

1. Router: extend `/api/task/:taskId/v1/messages` to also accept
   `/api/session/:sessionId/v1/messages` (or generalize the path segment),
   stamping `sessionId` on the `LlmCallRecord` alongside the existing
   `taskId` field (keep `taskId` nullable/optional rather than breaking the
   M24 contract immediately).
2. Daemon: `SessionRunner` (M30) sets the per-run `ANTHROPIC_BASE_URL` to the
   session-scoped router path; `/internal/llm-calls` persists `session_id`
   on `llm_calls` (migration adding the column, nullable for old rows).
3. `EvalStore#model_outcomes` and the `eval_dataset` view: decide and
   implement how "tests passed" attributes to a session with multiple
   messages (e.g. attribute to the most recent test run's result at call
   time) — write this decision down in this milestone's commit message and
   in STATUS.md, since it changes the meaning of the existing pass-rate
   numbers.
4. Tests: a session with two messages and an intervening test run produces
   correctly attributed `llm_calls` rows; `model_outcomes` rollup reflects
   the chosen attribution rule.

**Done when:** the attribution rule is implemented, documented, and tested;
router `npm run coverage` 100%; daemon `srb tc` + `rspec` 100%.

**Validate:**
`cd router && npm run build && npm test && npm run coverage` and
`cd daemon && bundle exec srb tc && bundle exec rspec`

---

### M34 — Retire the task-only surface (daemon/router scope)

- [x] M34 complete

**Goal:** once the session model (M29-M32) is proven, remove the
now-redundant task-only paths on the daemon/router side instead of carrying
two parallel primitives indefinitely. (The private repo's copy of this
milestone also removed the matching iOS task-only screens; that part is out
of scope here.)

**Steps:**

1. Confirm nothing in the daemon's own production wiring (`config.ru`, menu
   bar launch env) still depends on `/tasks/*` for normal operation; the
   low-cost eval harness (`scripts/low_cost_eval.rb`) is the one consumer
   most likely to need updating to the session contract — do that as part of
   this milestone, not as a follow-up.
2. Remove `/tasks/*` routes, `TaskStore`/`TaskRunner` (or fold their
   reusable internals into `SessionStore`/`SessionRunner` if duplication
   remains), the `tasks` table (migration to drop it, or a documented
   decision to keep it read-only for historical `llm_calls.task_id` joins —
   pick one and write down why).
3. Rewrite `docs/PLAN.md` in place so the "original task-based MVP" section
   is replaced by the session model as the only documented architecture.
4. Update `docs/STATUS.md`: collapse the "Architecture pivot" section into
   normal "Completed" entries once the migration is done.

**Done when:** there is exactly one primitive (`chat_sessions`/`messages`) in
the daemon and router; all validation commands for daemon/router pass; docs
describe only the new model.

**Validate:** `bundle exec srb tc && bundle exec rspec` (daemon),
`npm run build && npm test && npm run coverage` (router).

---

## Track H — Hardening for strangers (public subset)

The gap between "works for the author" and "works for a paying stranger".
Prerequisite for charging money. (M35, M37, M40, M41 — iOS-side reconnect,
discard UI, model picker, and Settings screen — stayed in the private repo;
M42 below is trimmed to its router/daemon scope.)

### M36 — Daemon: discard a session + worktree cleanup

- [x] M36 complete

**Goal:** sessions can be abandoned; worktrees/branches stop leaking.

**Steps:**

1. `git.rb`: add `worktree_remove(path, force: true)` and
   `branch_delete(name, force: true)`, tolerant of already-missing (return
   false, don't raise).
2. `SessionStore#discard(id)`: sets `status = 'discarded'`, keeps the row for
   stats/eval joins. Spec: `active_for_repo` excludes discarded so a new
   session can open.
3. `POST /sessions/:id/discard` in `app.rb` (auth): 404 unknown, 409 already
   approved/discarded; removes worktree at `worktrees_dir/<id>` and branch
   `relay/session/<id>`; broadcasts `session.updated`; returns session JSON.
4. Refuse discard while an agent run is in flight (409) — or document
   orphaned-but-harmless; pick one and test it.

**Done when:** discard removes worktree + branch (specs use real temp git
repos), events fire, coverage 100%.

**Validate:** `cd daemon && bundle exec srb tc && bundle exec rspec`

---

### M38 — Daemon: SQLite thread safety

- [x] M38 complete

**Goal:** stop sharing one `SQLite3::Database` across Puma threads
(`daemon/lib/relay_daemon/db.rb`).

**Steps:**

1. `Db#connection` returns a lazily-opened per-`Thread.current` connection:
   `results_as_hash`, `PRAGMA foreign_keys = ON`, `busy_timeout = 5000`,
   `PRAGMA journal_mode = WAL`.
2. `migrate!` runs exactly once per `Db` instance (Mutex-guarded, first
   connection).
3. Audit stores (`session_store`, `repo_store`, `llm_call_store`,
   `eval_store`, `pairing_service`, `stats`): must call `db.connection` per
   operation, not cache the raw handle at construction; fix any that cache.
4. Spec: N threads inserting/reading concurrently complete without
   `BusyException`/corruption; per-thread handles differ; migrations applied
   once.

**Done when:** concurrency spec passes reliably; existing specs green at
100%.

**Validate:** `cd daemon && bundle exec srb tc && bundle exec rspec`

---

### M39 — Daemon: model catalog endpoint

- [x] M39 complete

**Goal:** `GET /models` exposes live routing tiers so a client picker stops
being hardcoded.

**Steps:**

1. Typed `RelayDaemon::ModelCatalog`: reads JSON at
   `Config#routing_config_path`; absent/invalid → built-in constant mirroring
   the router's `DEFAULT_ROUTING_CONFIG` (`router/src/routing.ts`) —
   cross-reference comments in both files to catch drift.
2. `GET /models` (auth) →
   `{ "tiers": [{"tier": 0, "models": [...]}], "frontierModel": "...", "source": "file"|"default" }`,
   tiers ascending.
3. Specs: file-backed, missing-file default, malformed-file default; endpoint
   reflects a config written by `RoutingConfigWriter` (write → GET →
   reordered models visible).

**Done when:** all three catalog cases (file-backed, missing-file, malformed-
file) and the write-then-GET round trip are specced; coverage 100%.

**Validate:** `cd daemon && bundle exec srb tc && bundle exec rspec`

---

### M42 — Escalation auto-retry on failed tests (M26 follow-up, router/daemon scope)

- [x] M42 complete

**Goal:** a failed test run triggers one automatic agent run one tier up,
generating escalation-labeled eval data.

**Steps:**

1. Router: `matchMessagesPath` (`server.ts`) also accepts
   `/api/session/:sessionId/escalated/v1/messages` →
   `{ sessionId, escalated: true }`; escalated calls pass
   `escalationReason: "test_failure_retry"` to `chooseRoute` (existing +1
   tier mechanic applies).
2. Daemon: `POST /sessions/:id/test` accepts optional `"autoRetry": true`. On
   failure with autoRetry: append synthetic user message ("Tests
   failed:\n<last 50 lines>\nFix and keep changes minimal.") and run once via
   `SessionRunner.run_async` with `ANTHROPIC_BASE_URL` =
   `…/session/<id>/escalated`, resume mode. Exactly one retry per invocation,
   no recursion; normal WS events fire.
3. Tests: router path parse + escalated decision; daemon retry-once with
   fake failing test command + fake agent.

**Done when:** a failed test run produces exactly one escalated run
attributed in `llm_calls.escalation_reason`.

**Validate:**
`cd router && npm run build && npm test && npm run coverage`,
`cd daemon && bundle exec srb tc && bundle exec rspec`

---

## Track I — Named upstream providers (BYO endpoints)

Pro's headline feature: any OpenAI-compatible endpoint (local vLLM/Ollama,
corporate proxies). Design: routing config gains an optional `providers` map;
model ids may be `providerName::model-id`; bare ids keep meaning OpenRouter,
so every existing config parses unchanged. Custom-provider keys live in the
daemon's SQLite (user's own Mac, same trust domain as `.env`) and are written
inline into the routing config file with `0600` perms; the built-in
`openrouter` provider keeps using `OPENROUTER_API_KEY` from env and is never
persisted. (M46, the iOS custom-endpoints Settings UI, stayed in the private
repo.)

### M43 — Router: provider registry in the routing config

- [x] M43 complete

**Goal:** the routing config gains an optional `providers` map so model ids
can address named upstream endpoints, while every existing config keeps
parsing exactly as before.

**Steps:**

1. `routing.ts`: `RoutingConfig` gains
   `providers: Record<string, { baseUrl: string; apiKey?: string; apiKeyEnv?: string }>`
   (default `{}`). Validation: names `[a-z0-9_-]+`, `openrouter` reserved
   (rejected), `baseUrl` http(s); keys optional (keyless endpoints allowed,
   e.g. local vLLM).
2. New pure `resolveUpstream(modelId, config, options)`: `name::model` →
   provider's baseUrl, key from inline `apiKey` else
   `process.env[apiKeyEnv]`, model = part after `::`; unknown name throws. No
   `::` → built-in openrouter upstream from `RouterServerOptions`.
3. `chooseRoute`: a requested model containing `::` not in any tier routes
   directly to itself (routedModel = requested, tier = default rule's tier)
   — the per-request custom-endpoint path. Existing `findExactModelTier`
   still wins first.
4. Tests: parse (valid/invalid/reserved/absent), resolve (inline key, env
   key, keyless, unknown), direct `::` routing, all pre-existing config
   fixtures parse unchanged.

**Done when:** old configs parse identically; all new branches covered.

**Validate:** `cd router && npm run build && npm test && npm run coverage`

---

### M44 — Router: dispatch to the resolved provider

- [x] M44 complete

**Goal:** the router actually calls the resolved custom-provider endpoint
(not just OpenRouter) and attributes every call to the provider it used.

**Steps:**

1. Rename `callOpenRouter` → `callUpstream` (`server.ts`): POST
   `${baseUrl}/chat/completions`, `Authorization: Bearer <key>` only when a
   key exists; `HTTP-Referer`/`X-OpenRouter-Title` headers only for the
   openrouter upstream; send the resolved bare model (strip `name::`).
2. "OPENROUTER_API_KEY is required" error only when the *resolved* upstream
   is openrouter; custom keyless providers proceed.
3. `LlmCallRecord` (`call-log.ts`) gains `provider: string`; daemon migration
   adds nullable `provider` to `llm_calls`; `/internal/llm-calls` +
   `LlmCallStore` persist it; `eval_dataset` view exposes it.
4. Tests: fetch fake asserting URL/headers/model per provider, streaming +
   non-streaming, record includes provider; daemon specs for the column.

**Done when:** `myvllm::qwen3-32b` hits the fake custom baseUrl with the bare
model and lands in `llm_calls` with `provider = 'myvllm'`.

**Validate:**
`cd router && npm run build && npm test && npm run coverage` and
`cd daemon && bundle exec srb tc && bundle exec rspec`

---

### M45 — Daemon: provider store + config writer merge

- [x] M45 complete

**Goal:** custom providers are persisted on the daemon's own Mac and merged
into the routing config file the router reads, closing the loop end to end.

**Steps:**

1. Migration: `providers` table (`name` unique, `base_url`, `api_key`
   nullable, `models` JSON array, `created_at`).
2. Typed `ProviderStore` + routes: `GET /providers` (never returns
   `api_key`; returns `"hasApiKey"`), `POST /providers` (validate name
   pattern, reject `openrouter`, http(s) base_url), `DELETE /providers/:name`.
3. `RoutingConfigWriter#write!` merges a `providers` section (inline
   apiKey) into the config JSON, file mode `0600`. Also trigger writes on
   provider create/delete so the router hot-reloads immediately.
4. `GET /models` (M39) gains a `"custom"` group: each provider's declared
   models as `name::model` ids.
5. Specs: CRUD, key redaction, reserved-name rejection, writer merge + file
   mode, catalog inclusion.

**Done when:** POST provider → config file contains it (0600) →
`GET /models` lists its ids.

**Validate:** `cd daemon && bundle exec srb tc && bundle exec rspec`

---

## Track K — Open-core split + Homebrew distribution (public subset)

This track's split-process milestones (M53-M55, M61) documented how the
monorepo became two repos and stayed in the private repo as process history.
The milestones below describe work that happens *in* this repo now that it
exists.

### M56 — Public repo CI (GitHub Actions)

- [x] M56 complete

**Goal:** this repo gets CI so router/daemon/menubar changes are
checked automatically on every PR and push.

**Steps:**

1. `.github/workflows/ci.yml`: `router` job (ubuntu, Node 22,
   build+test+coverage), `daemon` job (ubuntu, Ruby 3.3 + bundler cache,
   `srb tc` + `rspec`), `menubar` job (macos-15 — Xcode 16 is needed to
   open xcodegen's objectVersion-77 projects — `brew install xcodegen`,
   test — path-gated to `menubar/**` to conserve macOS minutes).
2. Triggers: PR + push to master. No secrets needed (tests are network-free).

**Done when:** YAML is valid; CI runs green on this repo (user-checked).

**Validate:**
`cd router && npm run build && npm test && npm run coverage` and
`cd daemon && bundle exec srb tc && bundle exec rspec` (CI mirrors them).

---

### M57 — Daemon/router install-layout independence

- [x] M57 complete

**Goal:** daemon stops assuming it lives in a checkout next to `router/` —
a Homebrew prerequisite.

**Steps:**

1. `Config`: `router_dir` from `RELAY_ROUTER_DIR` (default: current
   `File.expand_path("../../router", __dir__)`), `router_command` from
   `RELAY_ROUTER_COMMAND` (default `["npm", "run", "start"]`).
2. `bin/daemon` feeds both to `RouterSupervisor`; clear failure if
   `router_dir` missing (unless `RELAY_SUPERVISE_ROUTER=0`).
3. Router: ensure prod start works from prebuilt `dist/` without dev deps
   (`node dist/index.js`; add `npm run start:prod` if needed).
4. Specs: config parsing of the new envs; supervisor receives them.

**Done when:** daemon boots with `RELAY_ROUTER_DIR` pointing at a copied
prebuilt router in a temp dir (manual).

**Validate:**
`cd daemon && bundle exec srb tc && bundle exec rspec` and
`cd router && npm run build && npm test && npm run coverage`

---

### M58 — Menubar: installed-daemon discovery + real Settings

- [x] M58 complete

**Goal:** the menubar app can find and launch a Homebrew-installed daemon
binary, not just a dev checkout, and exposes real settings for it.

**Steps:**

1. `DaemonController`: `resolveDaemonLaunch(env:exists:)` — ordered:
   `RELAY_DAEMON_BIN` env override → `/opt/homebrew/opt/relay/bin/
   relay-daemon` → `/usr/local/opt/relay/bin/relay-daemon` → dev checkout
   via existing `resolveRepoRoot`. Installed paths run the binary directly
   with `Process.environment` (no `/bin/zsh -lc`); zsh path only for the dev
   fallback.
2. Move hardcoded env (`RELAY_AGENT_COMMAND`, `ANTHROPIC_BASE_URL`, dummy
   key, host/port) into a `DaemonLaunchConfig` struct fed by UserDefaults,
   editable in a real Settings pane (replaces the stub `Settings` scene):
   bind-host override, agent command template, OpenRouter key presence
   hint, open-logs button.
3. Tests: resolution order (injected `exists`), direct-vs-shell selection,
   settings round-trip (suite-scoped UserDefaults).

**Done when:** a fake `relay-daemon` at a temp "opt" path is picked by the
resolver.

**Validate:**
`cd menubar && xcodegen generate && xcodebuild test -project RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS'`

---

### M59 — Release script + Homebrew formula

- [x] M59 complete

**Goal:** a scripted release process produces a tarball and a Homebrew
formula that installs the daemon + router.

**Steps:**

1. `scripts/release.sh`: for `vX.Y.Z` — clean tree + green gates,
   `npm ci && npm run build`, assemble `relay-server-X.Y.Z.tar.gz` (daemon/
   with Gemfile.lock, router/dist + package.json + package-lock.json,
   VERSION file), sha256, `gh release create`.
2. `packaging/homebrew/relay.rb` formula: `depends_on "node"`,
   `depends_on "ruby"` (≥3.3); install payload to libexec, `bundle install`
   (deployment mode) in `libexec/daemon`, `npm ci --omit=dev` in
   `libexec/router`; `bin/relay-daemon` wrapper exporting
   `RELAY_ROUTER_DIR=#{libexec}/router`,
   `RELAY_ROUTER_COMMAND=node dist/index.js`, brew ruby/node in PATH, exec
   the daemon. `test do` boots daemon on a free port and curls `/healthz`.
3. Document install in the public README: `brew tap <org>/relay && brew
   install relay && brew install --cask relay-menubar`.

**Done when:**
`brew install --build-from-source packaging/homebrew/relay.rb` against a
local tarball serves `/healthz` (manual, this Mac); release dry-run
produces a valid tarball.

**Validate:** `bash -n scripts/release.sh && brew style packaging/homebrew/relay.rb`

**Actual execution (2026-07-12):** `scripts/release.sh --dry-run v0.1.0`
ran every router/daemon gate, assembled a tracked-files-only tarball, and
rendered literal local/public formulas pinned to its version and SHA-256.
The local formula was installed from a temporary Homebrew tap with brewed
Ruby/Node; `brew test` booted the installed daemon and supervised router and
received a successful `/healthz` response. Strong review drove fixes for
Homebrew environment filtering, formula version/checksum drift, explicit
public-repository release targeting, ignored-file/secret exclusion, public
split coverage, startup retry behavior, and UTF-8 locale handling. The test
installation and temporary tap were removed afterward.

---

### M60 — Menubar notarization script + cask

- [ ] M60 complete

**Goal:** **User prerequisites (stop if missing):** a Developer ID
Application certificate must be in the keychain and
`xcrun notarytool store-credentials relay-notary` must have been run with
a valid App Store Connect API key. If either is missing, stop here per
AGENTS.md stop conditions and report what the user must provide before
implementing.

**Steps:**

1. `scripts/notarize_menubar.sh`: archive, export, `xcrun notarytool submit
   --wait`, staple, zip for cask distribution.
2. `packaging/homebrew/casks/relay-menubar.rb` cask pointing at the
   notarized zip + sha256.

**Done when:** `brew install --cask` (local file) installs a notarized,
Gatekeeper-clean app.

**Validate:** manual — `spctl -a -vv /Applications/RelayMenuBar.app` reports
accepted.

---

## Track M — Post-launch: push notifications + polish (public subset)

(M69, iOS push registration UI, stayed in the private repo.)

### M67 — Push relay worker

- [x] M67 complete

**Goal:** a minimal, privacy-preserving push relay exists as its own
service, tested like the router.

**Steps:**

1. New `push-relay/` — TypeScript Cloudflare Worker + Vitest with a coverage
   gate (mirror `router/` tooling): `POST /push` body
   `{ deviceToken, category: "agent_finished"|"tests_finished"|"needs_review", environment: "sandbox"|"production" }`.
2. ES256 APNs JWT from worker secrets (`APNS_KEY_P8`, `APNS_KEY_ID`,
   `APNS_TEAM_ID`) via WebCrypto; POST to
   `api(.sandbox).push.apple.com/3/device/<token>` with
   `apns-topic: dev.relay.ios` and a fixed category-keyed alert string — no
   caller-supplied text ever forwarded. Best-effort in-memory per-token
   rate limit.
3. Reject unknown categories/malformed tokens (400). `wrangler.toml`
   included; no state/KV; never log tokens.
4. Tests: JWT claims/signing (fake key), request shaping, category copy,
   rejections, rate limit — all against fake `fetch`.

**Done when:** JWT signing, request shaping, category copy, rejections, and
rate limiting are all unit-tested against a fake `fetch`; coverage gate
green.

**Validate:** `cd push-relay && npm run build && npm test && npm run coverage`

---

### M68 — Daemon: device tokens + push forwarding

- [x] M68 complete

**Goal:** the daemon stores push device tokens and forwards agent-finished/
tests-finished events to the push relay.

**Steps:**

1. Migration: `push_devices` (`device_token` unique, `created_at`). Routes
   (auth): `POST /push/devices`, `DELETE /push/devices/:token`.
2. `Config`: `RELAY_PUSH_RELAY_URL` (nil → feature fully disabled),
   `RELAY_PUSH_ENVIRONMENT` (default production).
3. Typed `PushNotifier.notify(category)`: posts
   `{deviceToken, category, environment}` per device, 3s timeout, rescues
   all errors (never blocks/fails the caller); injected HTTP for specs.
4. Hooks: end of `SessionRunner` run → `agent_finished`; test completion →
   `tests_finished`; accept `needs_review` category for later.
5. Specs: CRUD, disabled-when-unset, payload shape, error swallowing.

**Done when:** with a fake relay URL, a finished run produces exactly one
POST per device.

**Validate:** `cd daemon && bundle exec srb tc && bundle exec rspec`

---

### M70 — **User task:** APNs key + worker deploy + E2E

- [ ] M70 complete

**Goal:** **User task.** Provision the APNs key, deploy the push relay
worker, and run an end-to-end push test. The agent stops here per AGENTS.md
stop conditions (Apple developer portal and Cloudflare account actions
require the user's credentials).

**Steps:**

1. Create an APNs auth key (.p8) in the Apple developer portal.
2. Generate one relay shared secret without printing or committing it, deploy
   the push-relay worker, and set its four secrets (`APNS_KEY_P8`,
   `APNS_KEY_ID`, `APNS_TEAM_ID`, `RELAY_SHARED_SECRET`). The same generated
   value must be used for the daemon's `RELAY_PUSH_RELAY_TOKEN`:

   ```bash
   RELAY_SHARED_SECRET="$(openssl rand -hex 32)"
   printf '%s' "$RELAY_SHARED_SECRET" | npx wrangler secret put RELAY_SHARED_SECRET
   npx wrangler deploy
   ```

3. Configure the Mac user launch environment before launching/relaunching the
   menu bar app. The URL must be HTTPS with the exact `/push` path; the menu bar
   passes these values to the daemon without persisting the secret:

   ```bash
   launchctl setenv RELAY_PUSH_RELAY_URL 'https://<worker-host>/push'
   launchctl setenv RELAY_PUSH_RELAY_TOKEN "$RELAY_SHARED_SECRET"
   launchctl setenv RELAY_PUSH_ENVIRONMENT production
   unset RELAY_SHARED_SECRET
   osascript -e 'quit app "RelayMenuBar"' 2>/dev/null || true
   open -a RelayMenuBar
   ```

   Use `launchctl unsetenv` for all three names to disable/remove this
   configuration. Never put the shared secret in the repo, logs, command
   output, or menu bar defaults.
4. Enable the iOS notification toggle (M69).
5. Run a session, lock the phone, and confirm receipt of "Relay: agent
   finished".

**Done when:** the end-to-end push is received; recorded in
`docs/STATUS.md`.

**Validate:** No automated validate command — manual end-to-end push test,
recorded in `docs/STATUS.md`.
