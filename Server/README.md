# Nexus statistics API

Set `NEXUS_API_TOKEN` to a long random token, set `NEXUS_API_DATABASE` to a persistent SQLite path, and run `python3 Server/nexus_api.py` behind a TLS reverse proxy. The process listens on loopback by default. Configure the Nexus app with the HTTPS origin and the same token in Keychain.

`GET /api/nexus/v1/me` validates authentication. `POST /api/nexus/v1/statistics/events` accepts a JSON object with `schema_version: 1`, `device_id`, and up to 500 `events`. Each event has `id`, `time_ms`, `category`, `name`, and `count`. The primary key `(device_id, id)` makes retries idempotent. The response contains `accepted_ids`. `GET /api/nexus/v1/statistics/summary?start_ms=...&end_ms=...` returns sums for a left-closed, right-open UTC range. `GET /api/nexus/v1/statistics/events` returns up to 1000 records for restoration. `DELETE /api/nexus/v1/statistics/events?device_id=...` deletes one device's records.

The client keeps automatic upload off until the user enables it. Ordinary character keys use minute timestamps. Precise non-text timestamps require the separate switch in settings. This server does not include a public TLS deployment or account provisioning.

## Operation-history metadata API (schema_version 1)

These endpoints are **repository code only** until explicitly deployed to the HTTPS server. GitHub changes do not automatically change qsseda.com.

- `POST /api/nexus/v1/operations/events`: authenticated JSON batch, at most 25 operations, request body at most 1 MB. Returns `{"accepted_ids":["uuid",...]}`.
- `GET /api/nexus/v1/operations/events?start_ms=...&end_ms=...&offset=...`: UTC milliseconds, left-inclusive/right-exclusive, 100 records per page. Returns `{"operations":[{"device_id":"...","operation":{...}}],"next_offset":null}`.
- `DELETE /api/nexus/v1/operations/events?device_id=...`: deletes only this device's remote operations, never local SQLite history.

Each record includes a stable UUID, operation type and timestamps, detection/source type, status, and top-level `items` containing `position`, `name`, `source`, `extension`, `kind`, `size`. Nullable values are retained as null rather than guessed. `(device_id, operation_id)` is unique. Posting the same ID updates the existing metadata, never inserts a second event.

Client-side `operation_sync_state` acknowledges only validated accepted IDs. Failed network requests do not delete local history. Updating an explicitly computed folder size requeues the same UUID. Remote restore uses stable namespaced IDs, excludes imported records from re-upload, and remains idempotent.

**Privacy:** operation sync is independently off by default. Even when enabled, full source/target paths and clipboard text are separately off by default; fields are redacted in the serialized payload. No image pixels, thumbnails, binary content or keystroke sequences are uploaded.

**Deployment:** this does not provision Cloudflare secrets or production D1 migrations. Verify per-user authentication, secure storage, migration, retention and a real HTTPS endpoint before enabling live sync. This API is not end-to-end encrypted, and CloudKit/iOS clipboard synchronization is a separate phase.

Run local reference API tests:

```sh
python3 -m unittest discover -s Server -p 'test_nexus_api.py'
node --test Server/test_worker.mjs
```
