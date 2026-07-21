ALTER TABLE chat_sessions ADD COLUMN title TEXT;

UPDATE chat_sessions
SET title = (
  SELECT NULLIF(
    substr(trim(m.content, char(9) || char(10) || char(13) || char(32)), 1, 200),
    ''
  )
  FROM messages m
  WHERE m.session_id = chat_sessions.id
    AND m.role = 'user'
    AND NULLIF(trim(m.content, char(9) || char(10) || char(13) || char(32)), '') IS NOT NULL
  ORDER BY m.created_at ASC, m.rowid ASC
  LIMIT 1
)
WHERE title IS NULL;

CREATE INDEX idx_chat_sessions_repo_status_activity
ON chat_sessions (repo_id, status, last_message_at DESC, created_at DESC);
