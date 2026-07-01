ALTER TABLE llm_calls ADD COLUMN session_id TEXT REFERENCES chat_sessions(id);

CREATE TABLE session_test_runs (
  id           INTEGER PRIMARY KEY,
  session_id   TEXT    NOT NULL REFERENCES chat_sessions(id),
  tests_passed INTEGER,
  created_at   TEXT    NOT NULL
);

DROP VIEW IF EXISTS eval_dataset;

CREATE VIEW eval_dataset AS
SELECT
  c.id                AS call_id,
  c.task_id           AS task_id,
  NULL                AS session_id,
  c.task_id           AS outcome_id,
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
  t.repo_id           AS repo_id,
  r.name              AS repo_name,
  r.path              AS repo_path,
  t.prompt            AS task_prompt,
  t.quality_dial      AS quality_dial,
  t.status            AS outcome_status,
  t.tests_passed      AS tests_passed,
  t.finished_at       AS outcome_tested_at
FROM llm_calls c
JOIN tasks t ON t.id = c.task_id
JOIN repos r ON r.id = t.repo_id

UNION ALL

SELECT
  c.id                AS call_id,
  NULL                AS task_id,
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
  NULL                AS task_prompt,
  NULL                AS quality_dial,
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
