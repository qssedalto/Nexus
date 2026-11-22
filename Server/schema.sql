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

-- Stable (device_id, operation_id) keys keep operation retries idempotent.
-- Payload contains metadata plus optional, independently authorized sources/text.
CREATE TABLE IF NOT EXISTS operation_events (
  device_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  detected_time_ms INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  PRIMARY KEY (device_id, operation_id)
);
CREATE INDEX IF NOT EXISTS operation_events_range ON operation_events(detected_time_ms, device_id);
