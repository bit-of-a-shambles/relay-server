-- Adds 'discarded' as a valid chat_sessions.status value. SQLite has no
-- ALTER TABLE for CHECK constraints, so rebuild the table and re-copy rows.
--
-- The eval_dataset view (see 008_session_only_eval_dataset.sql) joins
-- chat_sessions. SQLite's ALTER TABLE RENAME re-resolves other schema
-- objects (including views) while it runs, which fails if chat_sessions is
-- briefly absent — so the view is dropped before the rebuild and recreated
-- identically to 008 afterward, the same drop/recreate pattern 008 itself
-- used when it replaced 007's view.
DROP VIEW IF EXISTS eval_dataset;

PRAGMA foreign_keys = OFF;

CREATE TABLE chat_sessions_new (
  id              TEXT    PRIMARY KEY,
  repo_id         INTEGER NOT NULL REFERENCES repos(id),
  branch          TEXT    NOT NULL,
  base_commit     TEXT    NOT NULL,
  status          TEXT    NOT NULL CHECK(status IN ('active','archived','discarded')),
  created_at      TEXT    NOT NULL,
  last_message_at TEXT
);

INSERT INTO chat_sessions_new (id, repo_id, branch, base_commit, status, created_at, last_message_at)
SELECT id, repo_id, branch, base_commit, status, created_at, last_message_at
FROM chat_sessions;

DROP TABLE chat_sessions;

ALTER TABLE chat_sessions_new RENAME TO chat_sessions;

PRAGMA foreign_keys = ON;

CREATE VIEW eval_dataset AS
SELECT
  c.id                AS call_id,
  c.session_id        AS session_id,
  COALESCE(
    c.session_id || ':test:' || (
      SELECT tr.id
      FROM session_test_runs tr
      WHERE tr.session_id = c.session_id
        AND tr.created_at >= c.created_at
      ORDER BY tr.created_at ASC, tr.id ASC
      LIMIT 1
    ),
    c.session_id || ':call:' || c.id
  )                   AS outcome_id,
  c.requested_model   AS requested_model,
  c.routed_model      AS routed_model,
  c.tier              AS tier,
  c.prompt_tokens     AS prompt_tokens,
  c.completion_tokens AS completion_tokens,
  c.cost_usd          AS cost_usd,
  c.frontier_cost_usd AS frontier_cost_usd,
  c.escalation_reason AS escalation_reason,
  c.status            AS call_status,
  c.created_at        AS call_created_at,
  s.repo_id           AS repo_id,
  r.name              AS repo_name,
  r.path              AS repo_path,
  s.status            AS outcome_status,
  (
    SELECT tr.tests_passed
    FROM session_test_runs tr
    WHERE tr.session_id = c.session_id
      AND tr.created_at >= c.created_at
    ORDER BY tr.created_at ASC, tr.id ASC
    LIMIT 1
  )                   AS tests_passed,
  (
    SELECT tr.created_at
    FROM session_test_runs tr
    WHERE tr.session_id = c.session_id
      AND tr.created_at >= c.created_at
    ORDER BY tr.created_at ASC, tr.id ASC
    LIMIT 1
  )                   AS outcome_tested_at
FROM llm_calls c
JOIN chat_sessions s ON s.id = c.session_id
JOIN repos r ON r.id = s.repo_id;
