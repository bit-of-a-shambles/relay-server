# relay-daemon

Ruby + Sorbet Mac-side service for Relay. It exposes the token-authenticated
REST/WebSocket API used by iOS, manages local Git repos and session worktrees,
runs the configured coding agent, records model-call cost data, and can
supervise the TypeScript router.

## Requirements

- Ruby 3.3+
- Bundler

## Install

```bash
cd daemon
bundle install
```

## Run

```bash
# Default: 127.0.0.1:7777
bin/daemon

# Custom host/port, for example a Tailscale address
RELAY_DAEMON_HOST=100.x.y.z RELAY_DAEMON_PORT=17777 bin/daemon
```

Health check:

```bash
curl http://127.0.0.1:7777/healthz
# {"status":"ok","version":"0.1.0"}
```

## Test

```bash
bundle exec srb tc
bundle exec rspec
```

## Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `RELAY_DAEMON_HOST` | `127.0.0.1` | Bind address |
| `RELAY_DAEMON_PORT` | `7777` | Listen port |
| `RELAY_DAEMON_TOKEN` | unset | Static bearer token for dev/tests |
| `RELAY_INTERNAL_TOKEN` | generated | Private router-to-daemon call-record token |
| `RELAY_DB_PATH` | `~/.relay/relay.sqlite3` | SQLite database path |
| `RELAY_WORKTREES_DIR` | `~/.relay/worktrees` | Session worktree root |
| `RELAY_AGENT_LOG_DIR` | `~/.relay/runs` | Session run/test log root |
| `RELAY_AGENT_COMMAND` | unset | Agent command template; `{prompt}` becomes one argv element |
| `RELAY_CLAUDE_STREAMING` | `1` | Set `0` to disable Claude partial-message output; custom agents are unaffected |
| `RELAY_ROUTER_BASE_URL` | unset | Router base URL, usually `http://127.0.0.1:7778/api` |
| `RELAY_ROUTING_CONFIG` | `~/.relay/routing.json` | Routing config path the daemon may rewrite from eval outcomes |
| `RELAY_LLM_CALL_SINK_URL` | loopback daemon `/internal/llm-calls` | Router call-record destination |
| `RELAY_LLM_CALL_SINK_TOKEN` | internal token | Bearer token for router call records |
| `RELAY_PUSH_RELAY_URL` | unset | Push Worker HTTPS URL with exact `/push` path; requires relay token |
| `RELAY_PUSH_RELAY_TOKEN` | unset | Bearer secret matching Worker `RELAY_SHARED_SECRET`; never logged |
| `RELAY_PUSH_ENVIRONMENT` | `production` | APNs environment: `production` or `sandbox` |
| `RELAY_SUPERVISE_ROUTER` | `1` | Set `0` to run daemon without starting the router |

## Harness and execution configuration

Discovery checks `claude`, `codex`, `gemini`, `copilot` and `omp` in PATH,
`~/.local/bin`, `~/.bun/bin`, and common Homebrew locations. Override an
individual path with `RELAY_HARNESS_CLAUDE_PATH`, `RELAY_HARNESS_CODEX_PATH`,
`RELAY_HARNESS_GEMINI_PATH`, `RELAY_HARNESS_COPILOT_PATH` or
`RELAY_HARNESS_OMP_PATH`; refresh discovery after changing installations.
A ready executable can still require its own provider sign-in.

Authenticated discovery/configuration endpoints:

```text
GET  /harnesses
POST /harnesses/refresh
GET  /execution-defaults
PUT  /execution-defaults
GET  /model-sources
POST /model-sources/refresh
GET  /approval-settings
PUT  /approval-settings
```

Create a session with an `execution` object containing `harnessId`,
`providerId`, `modelId` and `inferenceMode`. The Mac validates supported
combinations before running them. For example, `omp` with `openrouter` pins
the chosen OpenRouter model; `codex` with `doubleword` can select `async`.
Changing defaults affects future threads. Existing threads keep their choices.

Local model discovery uses Ollama `http://127.0.0.1:11434/v1` and LM Studio
`http://127.0.0.1:1234/v1` on the Mac. OpenRouter uses the Mac environment's
`OPENROUTER_API_KEY`. Doubleword can use `DOUBLEWORD_API_KEY` or saved provider
credentials. A custom endpoint must implement the protocol supported by the
selected harness. Gemini supports native Google models only. Gemini and
Oh My Pi require explicitly chosen `full_auto`; other harness permission
modes are reported in `/harnesses`. Credentials are not returned in discovery.

Native harness thread IDs are stored separately from Relay session IDs.
The included `bin/harness_bridge` normalizes native protocol output;
`bin/permission_hook` handles supported tool approvals. Both files must be
present beside `bin/daemon` in installed runtime packages.

## Agent Command

`RELAY_AGENT_COMMAND` is split into argv without a shell. When present,
`{prompt}` is replaced with the current user message. The legacy/custom Claude command path appends
Claude Code session flags:

- first run: `--session-id <session-uuid>`
- later runs: `--resume <session-uuid>`

If `RELAY_ROUTER_BASE_URL` is configured, the daemon sets:

```text
ANTHROPIC_BASE_URL=<router-base>/session/<session-id>/run/<run-id>
```

so model calls are attributed to both `llm_calls.session_id` and
`llm_calls.run_id`. `route_target` records Relay's selected direct or managed
target, while `routed_model` records the actual model reported upstream.

## API

```text
POST /pair/start
POST /pair/claim

GET  /fs/entries?path=...
GET  /repos
POST /repos

GET  /repos/:id/sessions
POST /repos/:id/sessions
POST /sessions
GET  /sessions/:id
PATCH /sessions/:id
GET  /sessions/:id/messages
POST /sessions/:id/messages
GET  /sessions/:id/diff
POST /sessions/:id/test
POST /sessions/:id/approve
POST /sessions/:id/discard

GET  /stats?range=30d
GET  /eval/model-outcomes
POST /internal/llm-calls
WS   /ws?token=...
```

Each repository can have multiple active chat sessions. `GET
/repos/:id/sessions` lists active sessions newest by message activity, while
`POST /repos/:id/sessions` always creates a fresh session and accepts an
optional title. `PATCH /sessions/:id` renames an active session. The legacy
`POST /sessions` route resumes the most recently active session for the repo,
or creates one when none exists.

`POST /sessions/:id/discard` abandons only the selected session: it removes
that session's worktree and branch, marks its row `discarded` (kept for stats/
eval history), and leaves sibling sessions active. Discarded sessions reject
message, test, approve, and rename mutations. Approve and discard operations
for sessions in the same repository are serialized.

## Remote access without a VPN

With the updated Mac companion and iPhone app, cloud pairing works across
separate networks, including cellular. Both peers connect outbound to a Worker;
your Mac can remain bound to loopback. Keep the Mac awake and online.

The hosted encrypted relay is enabled by default. Start/restart the daemon,
then scan a **new** QR or paste the full private
pairing link from `bin/daemon pair`. The URL and short code alone configure a
direct connection. Old pairings continue working directly; re-pair to add cloud
access. Direct LAN/Tailscale remains preferred when reachable. Set
`RELAY_TUNNEL_URL=` to disable cloud connections, or set it to your own WSS
origin to self-host. `RELAY_TUNNEL_STORE` optionally
changes the mode-0600 pairing file (default `~/.relay/cloud-pairings.json`).

Only routing capabilities and encrypted frames reach the Worker. QR secrets,
daemon bearer tokens, source code and messages stay encrypted between devices.
Do not share a QR or private pairing link. The same revocation commands below
also revoke cloud API/event access. See [the Worker runbook](../relay-tunnel/README.md)
for deployment, protocol details and transport size limits.

## Pairing

```bash
bin/daemon pair
# Pair your device with:
#   URL:  http://127.0.0.1:7777
#   Code: a1B2c3D4
```

The iOS app normally scans the menu-bar QR, but the code can also be claimed
manually:

```bash
curl -X POST http://127.0.0.1:7777/pair/claim \
  -H 'Content-Type: application/json' \
  -d '{"pairingCode":"a1B2c3D4"}'
# {"authToken":"<64 hex chars>"}
```

Codes are single-use and expire after 5 minutes. Auth accepts either
`RELAY_DAEMON_TOKEN` or an unrevoked paired token. Revoke with:

```bash
bin/daemon revoke <full-token-or-hash-prefix>
```

`bin/daemon` refuses public binds unless `--unsafe` is passed. For physical
direct iPhone testing with cloud disabled, bind to the Mac Tailscale IPv4:

```bash
RELAY_DAEMON_HOST="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 | head -n 1)" RELAY_DAEMON_PORT=17777 bin/daemon
```

## WebSocket Events

`GET /ws?token=<token>` first emits an authenticated `connection.ready` frame,
then streams JSON frames:

```json
{"type":"message.created","payload":{"sessionId":"...","message":{}}}
{"type":"assistant.updated","payload":{"sessionId":"...","agentRunId":"...","sequence":1,"content":"Cumulative assistant reply"}}
{"type":"agent.event","payload":{"sessionId":"...","agentRunId":"...","line":"..."}}
{"type":"session.updated","payload":{"sessionId":"...","repoId":1,"title":"...","status":"active","lastMessageAt":"..."}}
{"type":"stats.updated","payload":{}}
```

`assistant.updated` carries cumulative reply text and a monotonically increasing
sequence number. Clients replace the matching run's preview only when the
sequence advances, then replace that preview with the authoritative
`message.created` message. `agent.event` is reserved for agent diagnostics and
plain-command output.

A bad or missing token closes the socket with code `4401`.

## Session Walkthrough

This uses the fake session agent, so no OpenRouter key is required.

```bash
SAMPLE=$(mktemp -d)/sample-repo
mkdir -p "$SAMPLE"
cd "$SAMPLE"
git init -q
git config user.email "relay@test.local"
git config user.name "Relay Test"
echo "# Sample project" > README.md
git add README.md && git commit -q -m "initial"

export RELAY_DAEMON_TOKEN=walkthrough-token
export RELAY_DB_PATH=$(mktemp -d)/relay.sqlite3
export RELAY_WORKTREES_DIR=$(mktemp -d)/worktrees
export RELAY_AGENT_LOG_DIR=$(mktemp -d)/runs
export RELAY_AGENT_COMMAND="ruby /path/to/relay/daemon/spec/support/fake_session_agent.rb {prompt}"
export RELAY_SUPERVISE_ROUTER=0

cd /path/to/relay/daemon
bundle exec rackup --port 17777 --host 127.0.0.1 config.ru
```

In another terminal:

```bash
BASE=http://127.0.0.1:17777
AUTH="Authorization: Bearer walkthrough-token"

curl -s -X POST "$BASE/repos" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"path\":\"$SAMPLE\",\"testCommand\":null}"
# {"id":1,"path":".../sample-repo","name":"sample-repo","testCommand":null}

SESSION_ID=$(curl -s -X POST "$BASE/sessions" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"repoId":1}' | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")')

curl -s -X POST "$BASE/sessions/$SESSION_ID/messages" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"content":"Add a hello.rb file"}'
# {"id":"..."}

curl -s "$BASE/sessions/$SESSION_ID/messages" -H "$AUTH"
# user and assistant messages appear once the fake agent exits

curl -s "$BASE/sessions/$SESSION_ID/diff" -H "$AUTH"
# current per-file diff for the session worktree

curl -s -X POST "$BASE/sessions/$SESSION_ID/test" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"learnFromOutcome":false}'
# {"testsPassed":null}

curl -s -X POST "$BASE/sessions/$SESSION_ID/approve" -H "$AUTH"
# updated ChatSession; merge landed in the sample repo
```
