# relay-daemon

Ruby + Sorbet Mac-side service for Relay. Exposes a token-authenticated REST/WebSocket API on `127.0.0.1:7777`, supervises the TypeScript router, and manages coding-agent task lifecycle.

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

# Custom host/port
RELAY_DAEMON_HOST=0.0.0.0 RELAY_DAEMON_PORT=9000 bin/daemon
```

Or with rackup directly:

```bash
bundle exec rackup -p 7777 config.ru
```

Health check:

```bash
curl http://127.0.0.1:7777/healthz
# {"status":"ok","version":"0.1.0"}
```

## Test

```bash
bundle exec srb tc      # Sorbet typecheck (must pass with no errors)
bundle exec rspec       # Tests + SimpleCov (must reach 100% line coverage)
```

## Project layout

```
bin/daemon          Executable entry point
config.ru           Rack configuration
lib/
  relay_daemon/
    app.rb          Sinatra application
spec/
  spec_helper.rb    SimpleCov + RSpec config
  app_spec.rb       App tests
sorbet/             Sorbet RBI files (auto-generated, do not hand-edit gem stubs)
```

## Environment variables

| Variable               | Default       | Purpose                          |
|------------------------|---------------|----------------------------------|
| `RELAY_DAEMON_HOST`    | `127.0.0.1`   | Bind address                     |
| `RELAY_DAEMON_PORT`    | `7777`        | Listen port                      |
| `RELAY_DAEMON_TOKEN`   | —             | Bearer token for protected routes (M2+) |
| `RELAY_DB_PATH`        | `~/.relay/relay.sqlite3` | SQLite database path (M4+) |
| `RELAY_WORKTREES_DIR`  | `~/.relay/worktrees`     | Where task worktrees are created (M8+) |
| `RELAY_AGENT_LOG_DIR`  | `~/.relay/tasks`         | Per-task agent log directory (M8+) |
| `RELAY_AGENT_COMMAND`  | —             | Agent command template; `{prompt}` is replaced with the task prompt as a single argv element (M8+) |

## Agent command

`RELAY_AGENT_COMMAND` is split on whitespace into an argv array (no shell);
the `{prompt}` placeholder becomes one element. The production default for
Claude Code headless mode (verified against `claude --help`, June 2026) is:

```bash
RELAY_AGENT_COMMAND='claude -p {prompt} --permission-mode acceptEdits'
```

with env `ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api` and a dummy
`ANTHROPIC_API_KEY` so the agent talks to the local router. The daemon also
sets `RELAY_TASK_ID` in the agent's environment. Tests always use a fake
Ruby script instead (see `spec/support/`).

## Acceptance walkthrough

Proves the full Phase 3 lifecycle with HTTP + websocket clients alone.
Run from `daemon/`. Uses the fake diff agent (no API key needed); with an
`OPENROUTER_API_KEY` you can substitute the real Claude Code command from
the "Agent command" section above.

```bash
# 0. A sample repo to operate on
mkdir -p /tmp/relay-accept && cd /tmp/relay-accept
mkdir sample-repo && git -C sample-repo init
printf 'line1\n' > sample-repo/existing.txt
git -C sample-repo add . && git -C sample-repo commit -m initial

# 1. Start the daemon (pairing-only auth; no static token)
RELAY_DB_PATH=/tmp/relay-accept/relay.sqlite3 \
RELAY_WORKTREES_DIR=/tmp/relay-accept/worktrees \
RELAY_AGENT_LOG_DIR=/tmp/relay-accept/tasks \
RELAY_AGENT_COMMAND='ruby <repo>/daemon/spec/support/fake_diff_agent.rb {prompt}' \
RELAY_SUPERVISE_ROUTER=0 \
bin/daemon &

# 2. Pair and claim a token
bin/daemon pair
#   URL:  http://127.0.0.1:7777
#   Code: 9Y6aVuir
curl -X POST http://127.0.0.1:7777/pair/claim \
  -H 'Content-Type: application/json' -d '{"pairingCode":"9Y6aVuir"}'
# {"authToken":"0f69112884b4…d739c2"}
TOKEN=0f69112884b4…d739c2

# 3. Register the repo
curl -X POST http://127.0.0.1:7777/repos \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"path":"/tmp/relay-accept/sample-repo"}'
# {"id":1,"path":"/tmp/relay-accept/sample-repo","name":"sample-repo","testCommand":null}

# 4. Watch events (wscat, or any websocket client)
wscat -c "ws://127.0.0.1:7777/ws?token=$TOKEN" &

# 5. Create a task
curl -X POST http://127.0.0.1:7777/tasks \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"repoId":1,"prompt":"Add a new feature file","qualityDial":5}'
# {"id":"7f816425-…","status":"queued","branch":"relay/7f816425-…",
#  "baseCommit":"79fc2cc…","baseBranch":"master",…}
```

The websocket stream shows the lifecycle live (actual transcript from
this walkthrough, run 2026-06-12):

```
< {"type":"task.started","taskId":"7f816425-…","payload":{}}
< {"type":"task.needs_review","taskId":"7f816425-…","payload":{"testsPassed":null}}
< {"type":"stats.updated","taskId":"7f816425-…","payload":{}}
```

```bash
# 6. Inspect the diff
curl http://127.0.0.1:7777/tasks/7f816425-…/diff -H "Authorization: Bearer $TOKEN"
# [{"file":"existing.txt","unifiedDiff":"…+appended\n","additions":1,"deletions":0},
#  {"file":"new.txt","unifiedDiff":"…+created by agent\n","additions":1,"deletions":0}]

# 7. Approve (fast-forward merge into master)
curl -X POST http://127.0.0.1:7777/tasks/7f816425-…/approve -H "Authorization: Bearer $TOKEN"
# {"id":"7f816425-…","status":"approved",…}
# ws: {"type":"task.finished","taskId":"7f816425-…","payload":{"status":"approved"}}
# ws: {"type":"stats.updated","taskId":"7f816425-…","payload":{}}

# 8. Stats reflect the finished task
curl "http://127.0.0.1:7777/stats?range=7d" -H "Authorization: Bearer $TOKEN"
# {"range":"7d","spendUsd":0.0,"frontierCostUsd":0.0,"savedUsd":0.0,
#  "taskCount":1,"taskSuccessRate":1.0,"perModel":[]}

git -C /tmp/relay-accept/sample-repo log --oneline
# 13e9303 relay: task 7f816425-… result
# 79fc2cc initial
```

`RELAY_SUPERVISE_ROUTER=0` skips the router supervisor (useful when
testing the daemon alone); the default starts the router under
supervision.

## Pairing

```bash
# On the Mac, with the daemon running:
bin/daemon pair
# Pair your device with:
#   URL:  http://127.0.0.1:7777
#   Code: a1B2c3D4
```

No QR gem is used — the 8-character code is short enough to type, so
`bin/daemon pair` prints it as text. The client exchanges the code:

```bash
curl -X POST http://127.0.0.1:7777/pair/claim \
  -H 'Content-Type: application/json' \
  -d '{"pairingCode":"a1B2c3D4"}'
# {"authToken":"<64 hex chars>"} — shown exactly once; only its SHA-256 is stored
```

Codes are single-use and expire after 5 minutes. `POST /pair/start` is
localhost-only. Auth accepts either `RELAY_DAEMON_TOKEN` (dev/tests) or any
unrevoked paired token. Revoke with:

```bash
bin/daemon revoke <full-token-or-hash-prefix>
```

`bin/daemon` refuses to bind to anything other than loopback, RFC1918, or
Tailscale CGNAT (100.64/10) addresses unless `--unsafe` is passed.

## WebSocket events

`GET /ws?token=<daemon-token>` upgrades to a websocket and streams task
lifecycle events as JSON frames:

```json
{"type": "task.started",      "taskId": "…", "payload": {}}
{"type": "agent.event",       "taskId": "…", "payload": {"line": "…"}}
{"type": "task.needs_review", "taskId": "…", "payload": {"testsPassed": true}}
{"type": "task.finished",     "taskId": "…", "payload": {"status": "approved"}}
{"type": "stats.updated",     "taskId": "…", "payload": {}}
```

A bad or missing token closes the socket with code `4401`.

Manual verification (the socket handshake itself is covered by a
socketpair test; full end-to-end delivery over a live server is easiest
to check by hand):

```bash
RELAY_DAEMON_TOKEN=secret bin/daemon &
wscat -c "ws://127.0.0.1:7777/ws?token=secret"
# then create a task with curl and watch the frames arrive
```

## Phase 3 acceptance walkthrough

This walkthrough exercises the full task lifecycle using a fake agent
(`RELAY_AGENT_COMMAND`) so it requires no API key. Transcript verified
2026-06-12.

### Setup

```bash
# 1. Create a throwaway git repo to act as the sample workspace.
SAMPLE=$(mktemp -d)/sample-repo
mkdir -p "$SAMPLE"
cd "$SAMPLE"
git init -q
git config user.email "relay@test.local" && git config user.name "Relay Test"
echo "# Sample project" > README.md
git add README.md && git commit -q -m "initial"

# 2. Write a fake agent (no OpenRouter key needed).
FAKE_AGENT=$(mktemp)
cat > "$FAKE_AGENT" << 'EOF'
#!/bin/bash
echo "agent: received prompt: $1"
echo '# Added by relay agent' >> hello.rb
echo "puts 'hello from relay'" >> hello.rb
echo "agent: wrote hello.rb"
exit 0
EOF
chmod +x "$FAKE_AGENT"

# 3. Start the daemon on a spare port with the fake agent.
export RELAY_DAEMON_TOKEN=walkthrough-token
export RELAY_DB_PATH=$(mktemp -d)/relay.sqlite3
export RELAY_WORKTREES_DIR=$(mktemp -d)/worktrees
export RELAY_AGENT_LOG_DIR=$(mktemp -d)/tasks
export RELAY_AGENT_COMMAND="$FAKE_AGENT {prompt}"

cd /path/to/relay/daemon
nohup bundle exec rackup --port 17777 --host 127.0.0.1 config.ru > /tmp/relay-daemon.log 2>&1 &
sleep 2

BASE=http://127.0.0.1:17777
AUTH="Authorization: Bearer walkthrough-token"
```

### Walkthrough transcript

```
$ curl -s $BASE/healthz
{"status":"ok","version":"0.1.0"}

$ curl -s -X POST $BASE/repos \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"path\":\"$SAMPLE\",\"testCommand\":null}"
{"id":1,"path":"…/sample-repo","name":"sample-repo","testCommand":null}
# → HTTP 201

$ curl -s -X POST $BASE/tasks \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"repoId":1,"prompt":"Add a hello.rb file","qualityDial":5}'
{"id":"17ba30ad-25cc-49e8-8d9b-28ce73a463be","repoId":1,
 "prompt":"Add a hello.rb file","qualityDial":5,"status":"queued",
 "branch":"relay/17ba30ad-…","baseCommit":"945f8b4…","baseBranch":"main",
 "createdAt":"2026-06-12T19:06:57Z","finishedAt":null,
 "testsPassed":null,"costUsd":null,"savedUsd":null}
# → HTTP 201

# Agent runs immediately (fake script); poll for completion:
$ curl -s $BASE/tasks/17ba30ad-25cc-49e8-8d9b-28ce73a463be -H "$AUTH" | jq .status
"needs_review"

$ curl -s $BASE/tasks/17ba30ad-25cc-49e8-8d9b-28ce73a463be/diff -H "$AUTH"
[
  {
    "file": "hello.rb",
    "unifiedDiff": "diff --git a/hello.rb b/hello.rb\nnew file mode 100644\n…\n+# Added by relay agent\n+puts \"hello from relay\"\n",
    "additions": 2,
    "deletions": 0
  }
]

$ curl -s -X POST $BASE/tasks/17ba30ad-25cc-49e8-8d9b-28ce73a463be/approve \
    -H "$AUTH" | jq .status
"approved"
# → HTTP 200  (fast-forward merge landed on main)

$ curl -s $BASE/stats -H "$AUTH"
{
  "range": "30d",
  "spendUsd": 0.0,
  "frontierCostUsd": 0.0,
  "savedUsd": 0.0,
  "taskCount": 1,
  "taskSuccessRate": 1.0,
  "perModel": []
}

# Verify merge is in the sample repo:
$ git -C "$SAMPLE" log --oneline
4d884ef (HEAD -> main, relay/17ba30ad-…) relay: task 17ba30ad-… result
945f8b4 initial

$ cat "$SAMPLE/hello.rb"
# Added by relay agent
puts 'hello from relay'
```

### WebSocket monitoring (optional)

In a second terminal, connect before creating the task to watch events arrive:

```bash
wscat -c "ws://127.0.0.1:17777/ws?token=walkthrough-token"
# Frames you'll see when the task runs:
# {"type":"task.started","taskId":"…","payload":{}}
# {"type":"agent.event","taskId":"…","payload":{"line":"agent: received prompt: Add a hello.rb file"}}
# {"type":"agent.event","taskId":"…","payload":{"line":"agent: wrote hello.rb"}}
# {"type":"task.needs_review","taskId":"…","payload":{"testsPassed":null}}
# (after approve)
# {"type":"task.finished","taskId":"…","payload":{"status":"approved"}}
# {"type":"stats.updated","taskId":"…","payload":{}}
```
