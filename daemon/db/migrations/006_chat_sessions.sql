CREATE TABLE chat_sessions (
  id              TEXT    PRIMARY KEY,
  repo_id         INTEGER NOT NULL REFERENCES repos(id),
  branch          TEXT    NOT NULL,
  base_commit     TEXT    NOT NULL,
  status          TEXT    NOT NULL CHECK(status IN ('active','archived')),
  created_at      TEXT    NOT NULL,
  last_message_at TEXT
);

CREATE TABLE messages (
  id           TEXT    PRIMARY KEY,
  session_id   TEXT    NOT NULL REFERENCES chat_sessions(id),
  role         TEXT    NOT NULL CHECK(role IN ('user','assistant','tool','system')),
  content      TEXT    NOT NULL,
  created_at   TEXT    NOT NULL,
  agent_run_id TEXT
);
