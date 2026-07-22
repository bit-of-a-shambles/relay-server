# Relay Router

TypeScript Anthropic Messages API compatible proxy for Relay.

## Run

```sh
npm install
cp .env.example .env
npm run dev
```

Set `OPENROUTER_API_KEY` in `.env` before starting the router.
`RELAY_MAX_COMPLETION_TOKENS` defaults to `4096`; keep it low enough that
Claude Code's large completion ceilings do not exceed your OpenRouter credit
budget.

By default the router listens on `127.0.0.1:7778` and exposes:

```text
POST /api/v1/messages
GET  /health
```

Claude Code should point at:

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api
ANTHROPIC_API_KEY=dummy
```

Routing defaults to the built-in tier policy in `routing.example.json`. Tier
entries may be direct model IDs or named entries from `targets`. The bundled
managed targets map to OpenRouter Auto Beta and Pareto Code; direct models
remain first until outcome evals justify reordering. To force a model for quick
manual testing, use a routing config with the desired tier model.

Session-scoped requests include OpenRouter's `session_id` for provider/model
stickiness. Call records distinguish the selected `routeTarget` from the
actual response `routedModel` and include the daemon's `runId`.

To override routing, copy `routing.example.json` and set:

```sh
RELAY_ROUTING_CONFIG=./routing.json
```

To emit routing/cost records as JSONL until the daemon persists them:

```sh
RELAY_LLM_CALL_LOG=./llm-calls.jsonl
```

## Verify

```sh
npm run build
npm test
npm run coverage
npm run smoke:openrouter
```

`npm run smoke:openrouter` skips when `OPENROUTER_API_KEY` is not set.
