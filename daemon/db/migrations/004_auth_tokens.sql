CREATE TABLE auth_tokens (
  id         INTEGER PRIMARY KEY,
  token_hash TEXT    NOT NULL UNIQUE,
  label      TEXT,
  created_at TEXT    NOT NULL,
  revoked_at TEXT
);
