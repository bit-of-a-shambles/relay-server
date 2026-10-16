ALTER TABLE chat_sessions ADD COLUMN execution_config TEXT;
ALTER TABLE chat_sessions ADD COLUMN harness_session_id TEXT;
ALTER TABLE daemon_settings ADD COLUMN execution_defaults TEXT;
