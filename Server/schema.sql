CREATE TABLE IF NOT EXISTS input_events (
  device_id TEXT NOT NULL,
  event_id INTEGER NOT NULL,
  time_ms INTEGER NOT NULL,
  category TEXT NOT NULL,
  name TEXT NOT NULL,
  count INTEGER NOT NULL CHECK (count > 0),
  PRIMARY KEY (device_id, event_id)
);
CREATE INDEX IF NOT EXISTS input_events_range ON input_events(time_ms, device_id);
