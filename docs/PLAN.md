# Relay Plan

Relay is a mobile remote for a local Mac coding agent. A companion iOS app
(closed-source, separate private repo) gives the developer a continuous
Codex-like chat against a repo on their Mac; the Mac daemon in this repo runs
the agent locally; the router in this repo intercepts model calls and chooses
cheap or frontier models based on policy, overrides, and verified outcomes.

## Product Model

The active primitive is a repo-scoped chat session:

1. The client pairs with the Mac daemon over Tailscale or LAN.
2. The user registers or selects a local Git repo.
3. Relay opens one active `chat_session` for that repo, backed by a persistent
   session worktree and branch.
4. Each client message is appended to `messages` and sent to the local coding
   agent in that session worktree.
5. Agent output, assistant replies, diffs, tests, and approvals appear in one
   chat timeline instead of separate task screens.
6. Diff, test, and approve are explicit session actions. The session remains
   active after those actions so the conversation can continue.
7. Model routing is transparent by default, with per-message model override
   and a toggle controlling whether test outcomes update the eval dataset.

## Components

```text
router/     TypeScript Anthropic-compatible cost router
daemon/     Ruby + Sorbet Mac service, SQLite, Git worktrees, pairing
menubar/    Swift macOS status item wrapper
```

The router and daemon are separate local processes. The daemon supervises the
router when configured to do so, points the agent at the router with
`ANTHROPIC_BASE_URL`, and receives model call records through
`POST /internal/llm-calls`.

## Router

The router speaks the Anthropic Messages API on the listen side and forwards to
OpenRouter's OpenAI-compatible chat completions endpoint upstream. It translates
messages, tool calls, streaming deltas, and usage back to Anthropic shape so
existing coding agents can use it as their base URL.

Routing is config-driven and hot-reloaded:

- Tiers contain ordered model lists.
- Rules choose a base tier from request/model metadata.
- Quality dial or per-message model override can alter the decision.
- Upstream failures can retry at the next tier and record an escalation reason.
- Every attempt emits a call record with requested/routed model, tier, tokens,
  cost, frontier counterfactual cost, latency, status, and optional `sessionId`.

The router supports:

```text
POST /api/v1/messages
POST /api/session/:sessionId/v1/messages
GET  /health
```

There is no active task-scoped router route.

## Daemon

The daemon is the Mac-side source of truth. It:

- Authenticates REST and WebSocket clients with bearer tokens.
- Creates one-time pairing codes and claim tokens.
- Registers local Git repos and exposes a simple filesystem browser for repo
  selection.
- Opens or resumes one active chat session per repo.
- Runs the configured agent command in the session worktree.
- Captures agent stdout/stderr to per-session run logs and broadcasts live
  `agent.event` frames.
- Appends user and assistant messages to SQLite.
- Exposes current session diffs and runs the repo test command on demand.
- Records session test outcomes and optionally rewrites routing config from
  verified model outcomes.
- Approves a session by merging the session branch into the repo.
- Computes spend, savings, per-model usage, and outcome success metrics.

Primary REST/WS contract:

```text
POST /pair/start                    -> { qrPayload: { url, pairingCode } }
POST /pair/claim                    -> { authToken }

GET  /fs/entries?path=...
GET  /repos                         -> [{ id, path, name, testCommand }]
POST /repos                         { path, testCommand }

POST /sessions                      { repoId } -> ChatSession
GET  /sessions/:id/messages         -> [ChatMessage]
POST /sessions/:id/messages         { content, modelOverride? } -> 202 { id }
GET  /sessions/:id/diff             -> [DiffFile]
POST /sessions/:id/test             { learnFromOutcome } -> { testsPassed }
POST /sessions/:id/approve          -> ChatSession

GET  /stats?range=30d
GET  /eval/model-outcomes
POST /internal/llm-calls
WS   /ws?token=...
```

WebSocket events use a generic envelope:

```json
{ "type": "message.created", "payload": { "sessionId": "...", "message": {} } }
{ "type": "agent.event", "payload": { "sessionId": "...", "line": "..." } }
{ "type": "session.updated", "payload": { "sessionId": "..." } }
{ "type": "stats.updated", "payload": {} }
```

## Data Model

Active tables:

- `repos`
- `chat_sessions`
- `messages`
- `session_test_runs`
- `llm_calls`

`llm_calls.session_id` is the active attribution field for routing/eval.
`eval_dataset` is session-only: each attributed call is joined to the first
later session test run, so a long-running conversation can contribute multiple
verified outcomes.

The old physical `tasks` table and `llm_calls.task_id` column may remain in the
SQLite schema as read-only historical data to preserve old cost/eval records.
They are not active API primitives and should not be used by new product code.

## Security

- All daemon REST/WS routes require bearer auth except `/healthz` and `/pair/*`.
- Pairing codes are single-use, expire quickly, and exchange for random tokens.
- The daemon refuses unsafe public binds unless explicitly overridden.
- The OpenRouter key stays on the Mac/router side and is never sent to a client.
- Agent commands run in isolated session worktrees and merge only after user
  approval.

## Validation

Router:

```bash
cd router
npm run build
npm test
npm run coverage
```

Daemon:

```bash
cd daemon
bundle exec srb tc
bundle exec rspec
```

macOS menu bar:

```bash
cd menubar
xcodegen generate
xcodebuild test -project RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS'
```
