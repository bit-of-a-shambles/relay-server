CREATE TABLE inference_jobs (
  response_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES chat_sessions(id),
  run_id TEXT NOT NULL,
  status TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
