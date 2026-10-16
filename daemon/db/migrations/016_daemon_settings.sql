-- Single-row daemon-wide settings, starting with the tool-permission
-- approval mode (M87).
CREATE TABLE IF NOT EXISTS daemon_settings (
  id            INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
  approval_mode TEXT NOT NULL DEFAULT 'ask_on_sensitive'
);

INSERT INTO daemon_settings (id, approval_mode) VALUES (1, 'ask_on_sensitive');
