# Build Prompt: "Relay" - Mobile Remote + Cost Router for Coding Agents

You are a senior engineer building a production-quality MVP. Work in phases, verify each phase compiles and passes its acceptance criteria before moving on, and ask me before deviating from this spec.

## Product in one sentence

An iOS app that gives a developer a remote, continuous chat with a coding
agent running on their own Mac repo — closer to Codex than to a task queue —
where every model call is transparently routed through a cost-optimizing
proxy (cheap open-weight models by default, frontier models on escalation),
with per-session cost and outcome tracking, and where review/merge is a
checkpoint action inside the conversation rather than the end of every turn.

## Architecture model (2026-06-30 revision)

> **This supersedes the original "create task → wait → review → done" model
> described lower in this doc and reflected in the current `tasks`-table
> implementation.** The implementation has not been migrated yet; see
> [docs/AGENT_PLAYBOOK.md](docs/AGENT_PLAYBOOK.md) Track G for the migration
> milestones and [docs/STATUS.md](docs/STATUS.md) for current status.

Relay is a **remote chat UI for a local Mac coding agent**. The core
primitive is a **chat session** scoped to a repo, not a one-shot task:

1. **Pick a repo on the Mac.** The iOS app browses/selects a repo the daemon
   already knows about (or registers a new one). All work happens on that
   Mac's filesystem.
2. **Open a continuous chat.** The app creates or resumes a chat session for
   that repo. A session is long-lived: it is not "create task, wait, review,
   done" for every message — it is one running conversation the user returns
   to.
3. **Send messages into the same agent session.** Each user message
   continues the conversation. The agent retains context: prior turns, files
   it inspected, and previous changes in that session. This requires the
   underlying agent CLI process to be resumable/continuable per session
   (e.g. Claude Code's session-resume support), not re-spawned fresh per
   message.
4. **Stream back assistant/tool output as a timeline.** iOS shows a normal
   chat timeline: user messages, assistant responses, tool calls/output,
   file edits, errors, and test output, in order, per session — not a single
   collapsed task-result screen.
5. **Model routing happens underneath, unchanged in spirit.** The router
   still intercepts model calls and chooses cheap/better models unless the
   user overrides the model for that session/message. The eval toggle
   controls whether that session/message contributes to learned routing.
   Attribution moves from `task_id` to a session/message identity (see Track
   G in the playbook).
6. **Code changes stay local until reviewed.** The agent works in the Mac
   repo, on a session-scoped branch/worktree (this part is unchanged from the
   current implementation). Review/approve is a **checkpoint/merge action
   the user can take at any point in the session**, not something that
   automatically happens at the end of every chat turn.
7. **Tests/diffs are session actions, not lifecycle stages.** The user can
   ask the agent (in chat) to run tests, or tap explicit "run tests" / "review
   diff" controls. The app exposes the session's *current* diff and test
   state at any time, which can be queried repeatedly as the conversation
   continues — diffs and test runs are not a one-time end-of-task event.

The backend's core primitive shifts from `tasks` (one-shot, terminal status)
to **chat sessions + messages + local workspace state**, with
review/merge/test as session-level actions a user can invoke at any point,
any number of times, rather than a single terminal step per task. The
sections below (data model, REST/WS contract, iOS screens) describe the
**original task-based MVP that is currently implemented**; treat them as
history/reference until Track G's migration lands, at which point this file
should be rewritten in place rather than left with two competing models.

## What we are NOT building (MVP non-goals)

- No user accounts, no cloud backend, no billing. BYOK: the user supplies their own OpenRouter API key.
- No custom relay server. Assume the iPhone reaches the Mac over Tailscale or LAN (the user installs Tailscale themselves; we just document it).
- No Android, no watchOS, no web UI.
- No push notifications via APNs (requires a server). Use in-app live updates; local notifications only while the app is running.
- Do not fork or reimplement the coding agent. We wrap the existing Claude Code CLI in headless mode.

## Architecture (3 components, one repo)

```text
relay/
  router/     TypeScript. Anthropic-Messages-API-compatible proxy. Runnable standalone.
  daemon/     Ruby + Sorbet. Runs on the Mac. The brain.
  ios/        Swift 5.10+, SwiftUI, iOS 17+. The client.
  menubar/    Swift, macOS 14+. Thin status item wrapper that starts/stops the daemon. (Phase 5, optional.)
```

The router and daemon are separate local processes, not shared in-process modules. The daemon starts and supervises the router, points Claude Code at `ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api`, and receives routing/cost events from the router over a small authenticated local HTTP contract.

### Component 1: `router/` - the cost router

TypeScript, Node 20+, strict mode, vitest.

An HTTP proxy that speaks the **Anthropic Messages API** on the listen side (so Claude Code can point `ANTHROPIC_BASE_URL` at it) and forwards to **OpenRouter** (`https://openrouter.ai/api/v1`) on the upstream side, translating Anthropic-format requests to OpenAI chat-completions format and back, including tool-use blocks and streaming (SSE). This translation layer is the hardest part of the project - budget real effort for it, write it test-first against recorded fixtures of real Claude Code requests.

Routing policy (config file `routing.json`, hot-reloaded):

```jsonc
{
  "tiers": {
    "0": ["qwen/qwen3-coder-small"],
    "1": ["moonshotai/kimi-k2", "deepseek/deepseek-chat"],
    "2": ["anthropic/claude-sonnet-latest"],
    "3": ["anthropic/claude-opus-latest"]
  },
  "rules": [
    { "when": "requestedModel contains 'haiku'", "tier": 0 },
    { "when": "promptTokens > 60000", "tier": 2 },
    { "when": "default", "tier": 1 }
  ],
  "qualityDial": { "comment": "dial 0..10 shifts every decision up/down a tier: tier = clamp(baseTier + (dial-5)/3)" },
  "escalation": { "onTestFailure": "+1 tier for remainder of task", "onSameFileEditedThriceWithoutTestsPassing": "+1 tier" }
}
```

Every proxied call emits a routing/cost event containing the routing decision, token counts, cost (from OpenRouter's returned usage/pricing), and the counterfactual frontier cost. The daemon persists those events into `llm_calls`. Fail open: if a tier-0/1 model errors or returns malformed tool calls twice, retry at the next tier up and record `escalation_reason`.

### Component 2: `daemon/` - the Mac-side service

Ruby 3.3+ or current stable Ruby, with Sorbet for typed domain models and service boundaries.

Responsibilities:

1. Serve a WebSocket + REST API on `0.0.0.0:7777` (token-authenticated, see Security).
1. Start and supervise the local router process on `127.0.0.1:7778`.
1. Manage **sessions**: spawn the Claude Code CLI in headless/print mode (`claude -p "<task>" --output-format stream-json --verbose --permission-mode plan --no-session-persistence` or equivalent current flags - check `claude --help` at build time and adapt) inside a user-selected repo directory, with `ANTHROPIC_BASE_URL` pointed at the local router and a dummy API key.
1. Stream agent events (tool calls, text, file edits) to connected iOS clients over WebSocket.
1. Compute diffs: after the agent finishes (or at checkpoint), run `git diff` in the workspace and expose it per-file. Tasks run on a scratch branch (`relay/<task-id>`) created from the current HEAD; approval merges or leaves the branch, rejection deletes it. Never commit to the user's branch without approval.
1. Run the repo's test command (configurable per repo, e.g. `npm test`) after the agent finishes, record pass/fail.
1. Persist everything in SQLite via a Ruby SQLite library such as `sqlite3` or `sequel`: repos, tasks, sessions, per-request routing decisions, costs, outcomes.
1. Expose a `/stats` endpoint aggregating: total spend, estimated spend if everything had gone to the frontier model (computed from the same token counts at frontier prices), savings, task success rate, per-model breakdown.

Key REST/WS contract (JSON):

```text
POST /pair/start            -> { qrPayload }            # generates one-time pairing code, prints QR in terminal
POST /pair/claim            -> { authToken }            # exchange pairing code for long-lived token
GET  /repos                 -> [{ id, path, name, testCommand }]
POST /repos                 { path, testCommand }
POST /tasks                 { repoId, prompt, qualityDial }   # qualityDial 0..10
GET  /tasks/:id             -> { status, costUsd, savedUsd, testsPassed, branch }
GET  /tasks/:id/diff        -> [{ file, unifiedDiff, additions, deletions }]
POST /tasks/:id/approve     # merge scratch branch into original branch (fast-forward or merge commit)
POST /tasks/:id/reject      # delete scratch branch
GET  /stats?range=30d
WS   /ws?token=...          # server pushes: task.started, agent.event, task.needs_review, task.finished, stats.updated
```

Data model (SQLite tables): `repos`, `tasks(id, repo_id, prompt, quality_dial, status[queued|running|needs_review|approved|rejected|failed], branch, created_at, finished_at, tests_passed, cost_usd, frontier_cost_usd)`, `llm_calls(id, task_id, requested_model, routed_model, tier, prompt_tokens, completion_tokens, cost_usd, latency_ms, escalation_reason NULL)`.

### Component 3: `ios/` - the iPhone app

SwiftUI, MVVM, no third-party dependencies except what's necessary (prefer none; use URLSession WebSocket). Screens:

1. **Pairing** - scan QR from the daemon (payload: `{url, pairingCode}`), claim token, store in Keychain.
1. **Home / task launcher** - repo picker, multiline prompt field with dictation, quality dial (slider 0-10 labeled "Cheapest <-> Best"), Start button. Below: active sessions with live status.
1. **Session detail** - live feed of agent events (collapsed tool calls, streamed text), task status banner.
1. **Diff review** - triggered by `task.needs_review`: file list with +/- counts, per-file unified diff rendered with syntax-aware coloring (green/red lines is enough for MVP), Approve / Reject buttons, test-result badge ("tests passed" / "tests failed").
1. **Savings dashboard** - this month: spent, saved vs. frontier-only, success rate; per-model bar breakdown; simple list, no charting library needed.

Design: clean, dense, dark-mode-first, monospace for code/diffs, SF Symbols. No onboarding fluff.

### Security (non-negotiable)

- All HTTP/WS requires `Authorization: Bearer <token>`; pairing codes are single-use and expire in 5 minutes; tokens are 256-bit random, revocable via daemon CLI.
- The daemon refuses to start with a publicly routable bind unless `--unsafe` is passed; document Tailscale as the intended transport.
- Agent runs with Claude Code's own permission system in its default mode; the daemon never grants blanket `--dangerously-skip-permissions` unless the repo config explicitly opts in.
- The OpenRouter key lives only in the daemon's config on the Mac, never sent to the phone.

## Build phases & acceptance criteria

**Phase 1 - Router core.** Anthropic->OpenAI translation with streaming + tool use, forwarding to OpenRouter. Accept: Claude Code pointed at the router completes a real multi-tool task in a sample repo using a non-Anthropic model.

Status as of 2026-06-12: implementation and offline Claude Code compatibility are complete. The real OpenRouter acceptance smoke is blocked until `OPENROUTER_API_KEY` is configured.

**Phase 2 - Routing + logging.** Tier rules, escalation, SQLite logging, cost math, `/stats`. Accept: a task produces `llm_calls` rows showing >=2 different routed models, and `/stats` shows nonzero savings.

Status as of 2026-06-12: router-side routing rules, quality dial handling, retry escalation, JSONL call logging, and frontier cost estimates are implemented and tested. Daemon-owned SQLite persistence and `/stats` are not started.

**Phase 3 - Daemon session manager.** Task lifecycle, scratch branches, diff endpoint, test runner, WebSocket events, pairing. Accept: full task lifecycle driven by `curl` + `wscat` alone: create -> events stream -> diff retrievable -> approve merges branch.

**Phase 4 - iOS app.** All five screens against the live daemon. Accept: on a physical iPhone over Tailscale, I can start a task, watch it run, review the diff, approve it, and see the dashboard update.

**Phase 5 (optional) - macOS menu-bar wrapper.** Status item: daemon on/off, QR pairing window, link to logs.

Status as of 2026-06-24: Phases 1-5 are complete and accepted (see
[STATUS.md](STATUS.md)).

**Phase 6 - Chat-session architecture pivot.** Replace the task-as-primitive
model above with chat sessions + messages + local workspace state, per
"Architecture model (2026-06-30 revision)" earlier in this doc. Accept: a
user can open one chat session for a repo, send multiple messages that share
agent context/history, see a running timeline, and invoke diff/test/approve
as session actions at any point without the session ending. Tracked
milestone-by-milestone as Track G in
[AGENT_PLAYBOOK.md](AGENT_PLAYBOOK.md).

## Engineering standards

- TypeScript: strict mode, vitest, no `any` in router translation code.
- Ruby: Sorbet enabled for daemon domain models and service boundaries; avoid untyped core task/session/git lifecycle paths.
- Swift: no force-unwraps, async/await throughout.
- The router translation layer ships with recorded-fixture tests (capture real Claude Code request/response pairs in Phase 1 and check them in).
- README per component with exact run instructions, including separate Node and Ruby dependency setup; top-level README with the 10-minute setup path (install daemon, add OpenRouter key, install Tailscale, scan QR).
- When the Claude Code CLI's flags or the OpenRouter API differ from what's written here, trust the live `--help`/docs and tell me what changed.

## Current instruction

Continue from [STATUS.md](STATUS.md) and [AGENT_PLAYBOOK.md](AGENT_PLAYBOOK.md)
Track G. The original task-based MVP (Phases 1-5 above) is complete and
working; the next body of work is the architecture pivot described in
"Architecture model (2026-06-30 revision)" above — migrating the `tasks`
primitive to chat sessions + messages, one playbook milestone at a time, per
The Loop in [AGENTS.md](../AGENTS.md).
