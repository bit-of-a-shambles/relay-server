# Encrypted Relay tunnel

A Cloudflare Worker and hibernating Durable Object forward opaque WebSocket
frames between a paired Mac and iPhone. Both devices connect outbound using TLS;
there is no VPN, incoming firewall rule or public Mac port requirement.

## Deploy

Use Node 22 or later and a Cloudflare account with Workers access. For a new
Worker, current granular Cloudflare authorization requires Workers product Admin.
The legacy Edit Cloudflare Workers token template also supports deployment.
Keep the token in the environment or a secret manager; never commit it.

```
npm ci
npm run build
npm test
npm run coverage
npm run deploy -- --dry-run
npm run deploy
```

Set `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` for API authentication.
`wrangler.toml` creates a SQLite-backed Durable Object namespace and a connection
rate limiter. No application database or KV namespace is required.

The current Mac companion defaults to
`wss://relay-encrypted-tunnel.relay-tunnel.workers.dev`. For self-hosting, set
`RELAY_TUNNEL_URL=wss://<actual-worker-host>` in the Mac launch environment,
then restart the daemon. Set `RELAY_TUNNEL_URL=` to turn cloud connectivity off.
The phone obtains its endpoint from the Mac pairing QR.

Update the iPhone app and Mac companion together and scan a **new** pairing QR.
Old QR codes continue to work directly but do not contain cloud credentials.
The Mac must remain awake and online. Direct LAN/Tailscale is preferred when
reachable; cloud fallback works across separate networks and cellular.

## Security and privacy

Each QR contains a fresh 256-bit bootstrap secret. It expires for claiming after
five minutes. The iPhone stores the secret and daemon bearer token in its local,
non-synchronizing Keychain. The Mac stores secrets in a mode-0600 file. Do not
share screenshots of the QR or the private pairing link.

Routing capabilities are separately derived from that secret. The Worker sees
capabilities, peer IP addresses, connection timing and encrypted frame sizes. It
never receives the secret, daemon bearer token, prompts, code or decrypted events.
It keeps only live sockets and small routing/rate counters in socket attachments;
there is no payload logging, analytics, message database or replay queue.

P-256 ephemeral ECDH is authenticated by HMAC-SHA256 with the QR secret. Transcript-
bound HKDF-SHA256 produces directional ChaCha20-Poly1305 keys. Fresh ephemeral
keys per connection provide forward secrecy; ordered authenticated counters reject
replay and tampering. This protocol has cross-language golden-vector and negative
tests, but has not received an independent cryptographic audit.

The encrypted API still checks the existing revocable daemon bearer token. A room
is bound to its own claimed device token; Mac-only/internal endpoints are blocked.
Expired QR sockets close, and revoked devices cannot use API or event subscriptions.
Revocation stops a device; a fresh QR provides new routing capabilities if the QR
itself was exposed. Cloud failures surface bounded errors. Uncertain writes are
never automatically replayed over another route: check the thread before retrying.

HTTP replies are limited to 200 KB and encrypted envelopes to 512 KiB plaintext.
Large diffs/history may need a direct connection. The limits are enforced on both
peers and at the edge to bound memory use.

`../protocol-fixtures/tunnel-v1.json` contains intentionally public test keys only.
Ruby, Swift CryptoKit and Worker tests share it to verify wire compatibility and
that forwarded frames contain none of the plaintext markers or private keys.
