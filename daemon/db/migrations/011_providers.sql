-- Daemon-managed custom OpenAI-compatible providers (M45). ProviderStore
-- backs GET/POST /providers and DELETE /providers/:name; RoutingConfigWriter
-- merges every row here into the routing config's `providers` section (see
-- router M43/M44's ProviderConfig) so the router can resolve
-- `providerName::model` ids, and ModelCatalog lists them under GET /models'
-- "custom" group.
CREATE TABLE IF NOT EXISTS providers (
  name       TEXT PRIMARY KEY,
  base_url   TEXT NOT NULL,
  api_key    TEXT,
  models     TEXT NOT NULL,
  created_at TEXT NOT NULL
);
