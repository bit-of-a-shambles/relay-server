-- Push notification device tokens registered by the iOS client.
CREATE TABLE IF NOT EXISTS push_devices (
  device_token TEXT NOT NULL UNIQUE,
  created_at   TEXT NOT NULL
);
