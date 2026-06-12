CREATE TABLE repos (
  id          INTEGER PRIMARY KEY,
  path        TEXT    NOT NULL UNIQUE,
  name        TEXT    NOT NULL,
  test_command TEXT,
  created_at  TEXT    NOT NULL
);

CREATE TABLE tasks (
  id               TEXT    PRIMARY KEY,
  repo_id          INTEGER NOT NULL REFERENCES repos(id),
  prompt           TEXT    NOT NULL,
  quality_dial     INTEGER NOT NULL,
  status           TEXT    NOT NULL CHECK(status IN ('queued','running','needs_review','approved','rejected','failed')),
  branch           TEXT    NOT NULL,
  created_at       TEXT    NOT NULL,
  finished_at      TEXT,
  tests_passed     INTEGER,
  cost_usd         REAL,
  frontier_cost_usd REAL
);

CREATE TABLE llm_calls (
  id                INTEGER PRIMARY KEY,
  task_id           TEXT    REFERENCES tasks(id),
  requested_model   TEXT    NOT NULL,
  routed_model      TEXT    NOT NULL,
  tier              INTEGER NOT NULL,
  prompt_tokens     INTEGER NOT NULL,
  completion_tokens INTEGER NOT NULL,
  cost_usd          REAL,
  frontier_cost_usd REAL    NOT NULL,
  latency_ms        INTEGER NOT NULL,
  escalation_reason TEXT,
  status            TEXT    NOT NULL,
  error_message     TEXT,
  created_at        TEXT    NOT NULL
);
