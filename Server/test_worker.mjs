import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import worker from "./worker.js";

function environment() {
  const database = new DatabaseSync(":memory:");
  database.exec(readFileSync(new URL("./schema.sql", import.meta.url), "utf8"));
  return {
    API_TOKEN: "test-secret",
    DB: {
      prepare(sql) {
        return {
          bind(...values) {
            const statement = database.prepare(sql);
            return { all: async () => ({ results: statement.all(...values) }), run: async () => ({ meta: statement.run(...values) }) };
          },
        };
      },
      async batch(statements) {
        database.exec("BEGIN");
        try {
          const result = [];
          for (const statement of statements) result.push(await statement.run());
          database.exec("COMMIT");
          return result;
        } catch (error) {
          database.exec("ROLLBACK");
          throw error;
        }
      },
    },
  };
}

function request(path, method = "GET", body = undefined, token = "test-secret") {
  const text = body === undefined ? undefined : JSON.stringify(body);
  return new Request(`https://qsseda.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(text ? { "Content-Length": String(Buffer.byteLength(text)) } : {}) },
    body: text,
  });
}

test("API handshake reports authenticated operation support and version", async () => {
  const env = environment();
  const ok = await worker.fetch(request("/api/nexus/v1/me"), env);
  assert.equal(ok.status, 200);
  const hello = await ok.json();
  assert.equal(hello.authenticated, true);
  assert.equal(hello.schema_version, 1);
  assert.ok(hello.capabilities.includes("operations.events"));
  assert.ok(hello.capabilities.includes("statistics.monotonic_aggregates"));
  assert.ok(hello.capabilities.includes("operations.restore"));
  assert.equal((await worker.fetch(request("/api/nexus/v1/me", "GET", undefined, "wrong"), env)).status, 401);
});


test("bounded physical keys and generic chords survive the Worker API without accepting text", async () => {
  const env = environment();
  const endpoint = "/api/nexus/v1/statistics/events";
  const accepted = [
    ["ordinary", "character_total"], ["ordinary", "key_a"], ["ordinary", "shift_key_1"],
    ["ordinary", "key_semicolon"], ["keyboard", "f24"], ["keyboard", "num_lock"],
    ["shortcut", "control_shift_a"], ["shortcut", "command_shift_4"],
    ["shortcut", "option_command_semicolon"], ["shortcut", "fn_f1"],
    ["system", "spotlight_search"], ["system", "power"]
  ];
  const events = accepted.map(([category, name], i) => ({
    id: 100 + i, time_ms: 5000 + i, category, name, count: 1
  }));
  assert.equal((await worker.fetch(request(endpoint, "POST", {
    schema_version: 1, device_id: "general-keys", events
  }), env)).status, 200);
  const summary = await (await worker.fetch(request(
    "/api/nexus/v1/statistics/summary?start_ms=5000&end_ms=6000"
  ), env)).json();
  assert.equal(summary.statistics.reduce((n, row) => n + row.count, 0), events.length);
  const rejected = [
    ["ordinary", "typed_password"], ["ordinary", "key_password"],
    ["shortcut", "shift_a"], ["shortcut", "command_command_c"],
    ["shortcut", "command_private_text"], ["system", "unrecognized_system_key_99"],
    ["mouse", "mouse_extra_999"], ["ordinary", "key_a\n"]
  ];
  for (const [category, name] of rejected) {
    assert.equal((await worker.fetch(request(endpoint, "POST", {
      schema_version: 1, device_id: "invalid-keys",
      events: [{ id: 1, time_ms: 9000, category, name, count: 1 }]
    }), env)).status, 400, `${category}/${name} should be rejected`);
  }
});

test("authenticated uploads are idempotent and ranges use milliseconds", async () => {
  const env = environment();
  const path = "/api/nexus/v1/statistics/events";
  const batch = { schema_version: 1, device_id: "device-a", events: [
    { id: 1, time_ms: 1000, category: "keyboard", name: "escape", count: 2 },
    { id: 2, time_ms: 1001, category: "mouse", name: "mouse_left", count: 3 },
  ] };
  assert.equal((await worker.fetch(request(path, "POST", batch), env)).status, 200);
  assert.equal((await worker.fetch(request(path, "POST", batch), env)).status, 200);
  const first = await (await worker.fetch(request("/api/nexus/v1/statistics/summary?start_ms=1000&end_ms=1001"), env)).json();
  assert.equal(first.statistics[0].count, 2);
  const full = await (await worker.fetch(request("/api/nexus/v1/statistics/summary?start_ms=1000&end_ms=1002"), env)).json();
  assert.equal(full.statistics.reduce((sum, item) => sum + item.count, 0), 5);
  assert.equal((await worker.fetch(request("/api/nexus/v1/me", "GET", undefined, "wrong"), env)).status, 401);
});


test("lost acknowledgement retries keep aggregate counts monotonic", async () => {
  const env = environment();
  const path = "/api/nexus/v1/statistics/events";
  const initial = { schema_version: 1, device_id: "aggregate-device", events: [
    { id: 42, time_ms: 3_600_000, category: "ordinary", name: "character_total", count: 2 },
  ] };
  assert.equal((await worker.fetch(request(path, "POST", initial), env)).status, 200);
  const newer = { ...initial, events: [
    { ...initial.events[0], count: 3, time_ms: 3_600_500 },
  ] };
  assert.equal((await worker.fetch(request(path, "POST", newer), env)).status, 200);
  assert.equal((await worker.fetch(request(path, "POST", initial), env)).status, 200);

  const history = await (await worker.fetch(request(
    path + "?start_ms=3600000&end_ms=3601000"
  ), env)).json();
  assert.equal(history.events.length, 1);
  assert.equal(history.events[0].count, 3);
  assert.equal(history.events[0].time_ms, 3_600_000);
  const result = await (await worker.fetch(request(
    "/api/nexus/v1/statistics/summary?start_ms=3600000&end_ms=7200000"
  ), env)).json();
  assert.equal(result.statistics.length, 1);
  assert.equal(result.statistics[0].count, 3);
});

test("operation metadata retries, UTC ranges and device deletion are idempotent", async () => {
  const env = environment();
  const path = "/api/nexus/v1/operations/events";
  const operation = {
    id: "d8a68729-58d0-4c99-a223-88b19cd1e070",
    type: "path_copy", event_time_ms: null, detected_time_ms: 1234,
    completed_time_ms: null, source_application: "Nexus",
    detection_method: "nsservices", status: "clipboard_detected",
    target: null, duration_ms: null, clipboard_text: null,
    items: [{ position: 0, name: "文件.pvm", source: null, extension: "pvm",
              kind: "package", size: null }]
  };
  const batch = { schema_version: 1, device_id: "device-1", operations: [operation] };
  assert.equal((await worker.fetch(request(path, "POST", batch), env)).status, 200);
  assert.equal((await worker.fetch(request(path, "POST", batch), env)).status, 200);
  batch.operations[0].items[0].size = 123456;
  assert.equal((await worker.fetch(request(path, "POST", batch), env)).status, 200);
  const page = await (await worker.fetch(request(path + "?start_ms=1234&end_ms=1235"), env)).json();
  assert.equal(page.operations.length, 1);
  assert.deepEqual(page.operations[0].operation.items, operation.items);
  assert.equal((await (await worker.fetch(request(path + "?start_ms=1235&end_ms=1236"), env)).json()).operations.length, 0);
  assert.equal((await worker.fetch(request(path, "POST", batch, "wrong"), env)).status, 401);
  assert.equal((await (await worker.fetch(request(path + "?device_id=device-1", "DELETE"), env)).json()).deleted, 1);
  assert.equal((await (await worker.fetch(request(path + "?start_ms=0&end_ms=2000"), env)).json()).operations.length, 0);
});

test("operation endpoint rejects bad metadata and executable binary payloads", async () => {
  const env = environment();
  const path = "/api/nexus/v1/operations/events";
  const id = "aa2f0132-2f34-43bb-b6aa-32b4a7c10d32";
  const op = {
    id, type: "copy", detected_time_ms: 3, detection_method: "clipboard",
    status: "clipboard_detected", items: [{
      position: 0, name: "a.jpg", kind: "image", source: null, extension: "jpg", size: 12
    }]
  };
  assert.equal((await worker.fetch(request(path, "POST", { schema_version: 1, device_id: "d", operations: [op] }), env)).status, 200);
  assert.equal((await worker.fetch(request(path, "POST", { schema_version: 1, device_id: "d", operations: [{ ...op, items: [{ ...op.items[0], position: 9 }] }] }), env)).status, 400);
  assert.equal((await worker.fetch(request(path, "POST", { schema_version: 1, device_id: "d", operations: [{ ...op, id: "no-uuid" }] }), env)).status, 400);
  assert.equal((await worker.fetch(request(path, "POST", { schema_version: 1, device_id: "d", operations: [{ ...op, clipboard_text: "x".repeat(100001) }] }), env)).status, 400);
});


test("unexpected driver errors do not leak sensitive clipboard values into logs", async () => {
  const secret = "PRIVATE_CLIPBOARD_SECRET";
  const env = {
    API_TOKEN: "test-secret",
    DB: {
      prepare() {
        throw new Error(secret);
      },
    },
  };
  const messages = [];
  const originalError = console.error;
  console.error = (...args) => messages.push(args.map(String).join(" "));
  try {
    const response = await worker.fetch(request(
      "/api/nexus/v1/operations/events?start_ms=0&end_ms=1000"
    ), env);
    assert.equal(response.status, 500);
    assert.equal((await response.json()).error, "internal_error");
  } finally {
    console.error = originalError;
  }
  assert.ok(messages.some(message => message.includes("nexus_api_error")));
  assert.ok(messages.every(message => !message.includes(secret)));
});
