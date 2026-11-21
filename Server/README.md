# Nexus statistics API

Set `NEXUS_API_TOKEN` to a long random token, set `NEXUS_API_DATABASE` to a persistent SQLite path, and run `python3 Server/nexus_api.py` behind a TLS reverse proxy. The process listens on loopback by default. Configure the Nexus app with the HTTPS origin and the same token in Keychain.

`GET /api/nexus/v1/me` validates authentication. `POST /api/nexus/v1/statistics/events` accepts a JSON object with `schema_version: 1`, `device_id`, and up to 500 `events`. Each event has `id`, `time_ms`, `category`, `name`, and `count`. The primary key `(device_id, id)` makes retries idempotent. The response contains `accepted_ids`. `GET /api/nexus/v1/statistics/summary?start_ms=...&end_ms=...` returns sums for a left-closed, right-open UTC range. `GET /api/nexus/v1/statistics/events` returns up to 1000 records for restoration. `DELETE /api/nexus/v1/statistics/events?device_id=...` deletes one device's records.

The client keeps automatic upload off until the user enables it. Ordinary character keys use minute timestamps. Precise non-text timestamps require the separate switch in settings. This server does not include a public TLS deployment or account provisioning.
