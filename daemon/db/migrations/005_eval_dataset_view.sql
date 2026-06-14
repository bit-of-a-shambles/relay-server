-- The proprietary eval dataset: every routed model call joined to the task
-- whose tests verify it. INNER JOINs so only test-attributable calls appear
-- (calls with a null task_id are excluded). This is the (model × task →
-- tests-passed) signal the cost router learns from.
CREATE VIEW eval_dataset AS
SELECT
  c.id                AS call_id,
  c.task_id           AS task_id,
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
  t.status            AS task_status,
  t.tests_passed      AS tests_passed,
  t.finished_at       AS task_finished_at
FROM llm_calls c
JOIN tasks t ON t.id = c.task_id
JOIN repos r ON r.id = t.repo_id;
