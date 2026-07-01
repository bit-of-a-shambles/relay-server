DROP VIEW IF EXISTS eval_dataset;

-- Session-only active eval dataset. Historical task rows remain in the
-- database for old llm_calls.task_id references, but they are no longer an
-- active product primitive or routing input.
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
