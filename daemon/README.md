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
| `RELAY_DB_PATH` | `~/.relay/relay.sqlite3` | SQLite database path |
| `RELAY_WORKTREES_DIR` | `~/.relay/worktrees` | Session worktree root |
| `RELAY_AGENT_LOG_DIR` | `~/.relay/runs` | Session run/test log root |
| `RELAY_AGENT_COMMAND` | unset | Agent command template; `{prompt}` becomes one argv element |
| `RELAY_ROUTER_BASE_URL` | unset | Router base URL, usually `http://127.0.0.1:7778/api` |
| `RELAY_ROUTING_CONFIG` | unset | Routing config path the daemon may rewrite from eval outcomes |
| `RELAY_SUPERVISE_ROUTER` | `1` | Set `0` to run daemon without starting the router |

## Agent Command

`RELAY_AGENT_COMMAND` is split into argv without a shell. When present,
`{prompt}` is replaced with the current user message. `SessionRunner` appends
Claude Code session flags:

- first run: `--session-id <session-uuid>`
- later runs: `--resume <session-uuid>`

If `RELAY_ROUTER_BASE_URL` is configured, the daemon sets:

```text
ANTHROPIC_BASE_URL=<router-base>/session/<session-id>
```

so model calls are attributed to `llm_calls.session_id`.

## API

```text
POST /pair/start
POST /pair/claim

GET  /fs/entries?path=...
GET  /repos
POST /repos

POST /sessions
GET  /sessions/:id/messages
POST /sessions/:id/messages
GET  /sessions/:id/diff
POST /sessions/:id/test
POST /sessions/:id/approve

GET  /stats?range=30d
GET  /eval/model-outcomes
POST /internal/llm-calls
WS   /ws?token=...
```

Relay keeps one active chat session per repo. Posting `/sessions` repeatedly
for the same repo returns that active session.

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
iPhone testing, bind to the Mac Tailscale IPv4:

```bash
RELAY_DAEMON_HOST="$(tailscale ip -4 | head -n 1)" RELAY_DAEMON_PORT=17777 bin/daemon
```

## WebSocket Events

`GET /ws?token=<token>` streams JSON frames:

```json
{"type":"message.created","payload":{"sessionId":"...","message":{}}}
{"type":"agent.event","payload":{"sessionId":"...","agentRunId":"...","line":"..."}}
{"type":"session.updated","payload":{"sessionId":"..."}}
{"type":"stats.updated","payload":{}}
```

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
