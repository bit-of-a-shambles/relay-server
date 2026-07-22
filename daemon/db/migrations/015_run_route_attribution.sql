ALTER TABLE llm_calls ADD COLUMN run_id TEXT;
ALTER TABLE llm_calls ADD COLUMN route_target TEXT;

UPDATE llm_calls
SET route_target = routed_model
WHERE route_target IS NULL;

CREATE INDEX idx_llm_calls_run_id ON llm_calls(run_id);

DROP VIEW IF EXISTS eval_dataset;

CREATE VIEW eval_dataset AS
SELECT
  c.id                AS call_id,
  c.session_id        AS session_id,
  c.run_id            AS run_id,
  CASE
    WHEN tr.id IS NULL THEN c.session_id || ':call:' || c.id
    ELSE c.session_id || ':test:' || tr.id
  END                 AS outcome_id,
  c.requested_model   AS requested_model,
  COALESCE(c.route_target, c.routed_model) AS route_target,
  c.routed_model      AS routed_model,
  c.provider          AS provider,
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
  tr.tests_passed     AS tests_passed,
  tr.created_at       AS outcome_tested_at
FROM llm_calls c
JOIN chat_sessions s ON s.id = c.session_id
JOIN repos r ON r.id = s.repo_id
LEFT JOIN session_test_runs tr ON tr.id = (
  SELECT candidate.id
  FROM session_test_runs candidate
  WHERE candidate.session_id = c.session_id
    AND candidate.created_at >= c.created_at
  ORDER BY candidate.created_at ASC, candidate.id ASC
  LIMIT 1
)
WHERE tr.id IS NULL OR tr.learn_from_outcome = 1;
