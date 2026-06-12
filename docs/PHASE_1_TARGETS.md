# Phase 1 Targets To Confirm

## Claude Code headless command

Based on local `claude --help` output on 2026-06-11, Phase 1 should target this command shape:

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api \
ANTHROPIC_API_KEY=dummy \
claude --print "<task>" \
  --output-format stream-json \
  --verbose \
  --permission-mode plan \
  --include-partial-messages \
  --no-session-persistence
```

Notes:

- `-p, --print` is the supported non-interactive/headless mode.
- `--output-format stream-json` is supported for realtime output, and this local Claude Code build requires `--verbose` with `--print` when stream-json output is selected.
- `--permission-mode plan` is currently a valid permission mode.
- `--include-partial-messages` is supported with `--print` and `--output-format=stream-json`.
- `--no-session-persistence` should be used for daemon-created one-shot task runs unless persistence becomes useful for resume/debug.
- I would not use `--dangerously-skip-permissions` in Phase 1.

## Router listen-side endpoints

The local router should expose the Anthropic-compatible API under:

```text
POST http://127.0.0.1:7778/api/v1/messages
```

Claude Code will receive:

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api
```

## OpenRouter upstream endpoints

Based on OpenRouter docs checked on 2026-06-11:

```text
POST https://openrouter.ai/api/v1/chat/completions
GET  https://openrouter.ai/api/v1/models
```

The Phase 1 proxy originally forwarded single-model requests to `POST /api/v1/chat/completions` with:

```http
Authorization: Bearer <OPENROUTER_API_KEY>
Content-Type: application/json
HTTP-Referer: relay.local
X-OpenRouter-Title: Relay
```

## Open question

OpenRouter also documents an Anthropic-compatible "Anthropic Skin" at `ANTHROPIC_BASE_URL=https://openrouter.ai/api`. For this project, I will still implement the requested local Anthropic-to-OpenAI translation layer in Phase 1, using OpenRouter's OpenAI-compatible chat completions endpoint upstream.

## Current status

As of 2026-06-12, the router no longer uses a static single-model path internally. Routing decisions now come from the built-in tier policy or `RELAY_ROUTING_CONFIG`. The real OpenRouter smoke still depends on setting `OPENROUTER_API_KEY`.
