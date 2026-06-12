# Relay Router

TypeScript Anthropic Messages API compatible proxy for Relay.

## Run

```sh
npm install
cp .env.example .env
npm run dev
```

Set `OPENROUTER_API_KEY` in `.env` before starting the router.

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

Routing defaults to the built-in tier policy in `routing.example.json`. To force a model for quick manual testing, use a routing config with the desired tier model.

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
