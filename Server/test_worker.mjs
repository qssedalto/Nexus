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
