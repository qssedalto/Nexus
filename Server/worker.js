const allowed = {
  ordinary: new Set(["character_total"]),
  keyboard: new Set(["escape", "delete", "forward_delete", "return", "tab", "space", "left", "right", "up", "down", "home", "end", "page_up", "page_down", "scroll_lock", "insert", "num_lock"]),
  modifier: new Set(["left_command", "right_command", "left_option", "right_option", "left_control", "right_control", "left_shift", "right_shift", "caps_lock", "fn"]),
  shortcut: new Set(["command_c", "command_v", "command_x", "command_z", "command_shift_z", "command_tab", "command_space", "command_q", "control_command_q", "command_escape", "command_option_escape"]),
  mouse: new Set(["mouse_left", "mouse_right", "mouse_middle", "mouse_back", "mouse_forward"]),
  scroll: new Set(["scroll_up", "scroll_down", "scroll_left", "scroll_right"]),
  system: new Set(["volume_up", "volume_down", "brightness_up", "brightness_down", "mute", "play_pause", "next", "previous", "fast_forward", "rewind", "keyboard_light_up", "keyboard_light_down", "keyboard_light_toggle", "caps_lock_on", "caps_lock_off", "power", "sleep", "media_record", "stop", "eject", "calculator", "screensaver", "spotlight_search", "fn"]),
};

function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

async function authorized(request, token) {
  if (!token) return false;
  const received = request.headers.get("Authorization") || "";
  const expected = `Bearer ${token}`;
  const [actualHash, expectedHash] = await Promise.all(
    [received, expected].map(async value => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))))
  );
  let difference = 0;
  for (let index = 0; index < expectedHash.length; index++) difference |= actualHash[index] ^ expectedHash[index];
  return difference === 0;
}

function bounds(url) {
  const start = Number(url.searchParams.get("start_ms"));
  const end = Number(url.searchParams.get("end_ms"));
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end <= start) return null;
  return { start, end, device: url.searchParams.get("device_id") };
}

// Accept bounded physical-key identifiers and combinations, never raw input
// text. Keep legacy aggregate names for backward-compatible synchronization.
const physicalKey = /^(?:[a-z0-9]|semicolon|comma|slash|period|equal|minus|left_bracket|right_bracket|quote|backslash|grave|keypad_(?:[0-9]|decimal|multiply|plus|clear|divide|enter|minus|equal))$/;
const functionKey = /^f(?:[1-9]|1\d|2[0-4])$/;
const modifiers = new Set(["control", "option", "command", "shift", "fn"]);

function validEventName(category, name) {
  if (typeof category !== "string" || typeof name !== "string" ||
      !/^[a-z0-9_]{1,80}$/.test(name)) return false;
  if (allowed[category]?.has(name)) return true;
  if (category === "ordinary") {
    if (name.startsWith("shift_key_")) return physicalKey.test(name.slice(10));
    if (name.startsWith("key_")) return physicalKey.test(name.slice(4));
  }
  if (category === "keyboard") return functionKey.test(name);
  if (category === "mouse") return /^mouse_extra_\d{1,2}$/.test(name);
  if (category === "shortcut") {
    const parts = name.split("_");
    const active = [];
    while (parts.length && modifiers.has(parts[0])) active.push(parts.shift());
    const base = parts.join("_");
    if (!active.length || active.length > modifiers.size ||
        new Set(active).size !== active.length ||
        !active.some(modifier => modifier !== "shift")) return false;
    return physicalKey.test(base) || functionKey.test(base) || allowed.keyboard.has(base);
  }
  return false;
}

function validEvent(event) {
  if (!event || !Number.isSafeInteger(event.id) || event.id < 0 ||
      !Number.isSafeInteger(event.time_ms) || event.time_ms < 0) return false;
  if (!Number.isSafeInteger(event.count) || event.count < 1 || event.count > 1_000_000) return false;
  return validEventName(event.category, event.name);
}

// This endpoint never inspects image bytes. It carries bounded metadata and
// only optional text/paths independently approved by the desktop user.
function validOperation(op) {
  if (!op || typeof op !== "object") return false;
  if (typeof op.id !== "string" || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(op.id)) return false;
  const integer = value => Number.isSafeInteger(value) && value >= 0;
  const optionalInteger = value => value == null || integer(value);
  const optionalString = (value, maximum) => value == null || (typeof value === "string" && value.length <= maximum);
  if (!integer(op.detected_time_ms) || !optionalInteger(op.event_time_ms) ||
      !optionalInteger(op.completed_time_ms) || !optionalInteger(op.duration_ms)) return false;
  if (typeof op.type !== "string" || !/^[a-z_]{1,32}$/.test(op.type) ||
      typeof op.detection_method !== "string" || !/^[a-z_]{1,40}$/.test(op.detection_method) ||
      typeof op.status !== "string" || !/^[a-z_]{1,40}$/.test(op.status)) return false;
  if (!optionalString(op.source_application, 256) || !optionalString(op.target, 4096) ||
      !optionalString(op.clipboard_text, 100000)) return false;
  if (!Array.isArray(op.items) || op.items.length > 100) return false;
  const positions = new Set();
  for (const item of op.items) {
    if (!item || !integer(item.position) || item.position >= op.items.length ||
        positions.has(item.position)) return false;
    positions.add(item.position);
    if (typeof item.name !== "string" || item.name.length > 1024 ||
        typeof item.kind !== "string" || !/^[a-z_]{1,32}$/.test(item.kind) ||
        !optionalString(item.source, 4096) || !optionalString(item.extension, 64) ||
        !optionalInteger(item.size)) return false;
  }
  return true;
}

export default {
  async fetch(request, env) {
    try {
      if (!(await authorized(request, env.API_TOKEN))) return json({ error: "unauthorized" }, 401);
      const url = new URL(request.url);
      const path = url.pathname;
      if (path === "/api/nexus/v1/me" && request.method === "GET") {
        return json({
          authenticated: true,
          schema_version: 1,
          capabilities: ["statistics.events", "statistics.summary", "statistics.monotonic_aggregates", "operations.events", "operations.restore"]
        });
      }
      if (path === "/api/nexus/v1/operations/events" && request.method === "POST") {
        const length = Number(request.headers.get("Content-Length"));
        if (!Number.isSafeInteger(length) || length < 1 || length > 1_000_000) return json({ error: "invalid_size" }, 400);
        const body = await request.json().catch(() => null);
        if (body?.schema_version !== 1 || typeof body.device_id !== "string" ||
            body.device_id.length < 1 || body.device_id.length > 80 ||
            !Array.isArray(body.operations) || body.operations.length < 1 ||
            body.operations.length > 25 || !body.operations.every(validOperation)) return json({ error: "invalid_request" }, 400);
        const statements = body.operations.map(op => env.DB.prepare(
          "INSERT INTO operation_events(device_id,operation_id,detected_time_ms,payload_json) VALUES(?,?,?,?) ON CONFLICT(device_id,operation_id) DO UPDATE SET detected_time_ms=excluded.detected_time_ms, payload_json=excluded.payload_json"
        ).bind(body.device_id, op.id, op.detected_time_ms, JSON.stringify(op)));
        await env.DB.batch(statements);
        return json({ accepted_ids: body.operations.map(op => op.id) });
      }
      if (path === "/api/nexus/v1/operations/events" && request.method === "GET") {
        const range = bounds(url);
        if (!range) return json({ error: "invalid_range" }, 400);
        const offset = Number(url.searchParams.get("offset") || 0);
        if (!Number.isSafeInteger(offset) || offset < 0 || offset > 1_000_000) return json({ error: "invalid_offset" }, 400);
        const result = await env.DB.prepare(
          "SELECT device_id, payload_json FROM operation_events WHERE detected_time_ms >= ? AND detected_time_ms < ? AND (? IS NULL OR device_id = ?) ORDER BY detected_time_ms,device_id,operation_id LIMIT 100 OFFSET ?"
        ).bind(range.start, range.end, range.device, range.device, offset).all();
        return json({
          operations: result.results.map(item => ({ device_id: item.device_id, operation: JSON.parse(item.payload_json) })),
          next_offset: result.results.length === 100 ? offset + 100 : null,
        });
      }
      if (path === "/api/nexus/v1/operations/events" && request.method === "DELETE") {
        const device = url.searchParams.get("device_id");
        if (!device) return json({ error: "device_id_required" }, 400);
        const result = await env.DB.prepare("DELETE FROM operation_events WHERE device_id = ?").bind(device).run();
        return json({ deleted: result.meta.changes });
      }
      if (path === "/api/nexus/v1/statistics/events" && request.method === "POST") {
        const length = Number(request.headers.get("Content-Length"));
        if (!Number.isSafeInteger(length) || length < 1 || length > 1_000_000) return json({ error: "invalid_size" }, 400);
        const body = await request.json().catch(() => null);
        if (body?.schema_version !== 1 || typeof body.device_id !== "string" || !body.device_id || body.device_id.length > 80 || !Array.isArray(body.events) || body.events.length > 500 || !body.events.every(validEvent)) return json({ error: "invalid_request" }, 400);
        const statements = body.events.map(event => env.DB.prepare(
          "INSERT INTO input_events(device_id, event_id, time_ms, category, name, count) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(device_id, event_id) DO UPDATE SET count = MAX(input_events.count, excluded.count), time_ms = MIN(input_events.time_ms, excluded.time_ms)"
        ).bind(body.device_id, event.id, event.time_ms, event.category, event.name, event.count));
        if (statements.length) await env.DB.batch(statements);
        return json({ accepted_ids: body.events.map(event => event.id) });
      }
      if (path === "/api/nexus/v1/statistics/summary" && request.method === "GET") {
        const range = bounds(url);
        if (!range) return json({ error: "invalid_range" }, 400);
        const result = await env.DB.prepare(
          "SELECT category, name, SUM(count) AS count FROM input_events WHERE time_ms >= ? AND time_ms < ? AND (? IS NULL OR device_id = ?) GROUP BY category, name ORDER BY category, name"
        ).bind(range.start, range.end, range.device, range.device).all();
        return json({ start_ms: range.start, end_ms: range.end, statistics: result.results });
      }
      if (path === "/api/nexus/v1/statistics/events" && request.method === "GET") {
        const range = bounds(url);
        if (!range) return json({ error: "invalid_range" }, 400);
        const offset = Number(url.searchParams.get("offset") || 0);
        if (!Number.isSafeInteger(offset) || offset < 0 || offset > 1_000_000) return json({ error: "invalid_offset" }, 400);
        const result = await env.DB.prepare(
          "SELECT device_id, event_id AS id, time_ms, category, name, count FROM input_events WHERE time_ms >= ? AND time_ms < ? AND (? IS NULL OR device_id = ?) ORDER BY time_ms, device_id, event_id LIMIT 1000 OFFSET ?"
        ).bind(range.start, range.end, range.device, range.device, offset).all();
        return json({ events: result.results, next_offset: result.results.length === 1000 ? offset + 1000 : null });
      }
      if (path === "/api/nexus/v1/statistics/events" && request.method === "DELETE") {
        const device = url.searchParams.get("device_id");
        if (!device) return json({ error: "device_id_required" }, 400);
        const result = await env.DB.prepare("DELETE FROM input_events WHERE device_id = ?").bind(device).run();
        return json({ deleted: result.meta.changes });
      }
      return json({ error: "not_found" }, 404);
    } catch {
      // Driver exceptions may embed SQL values or personal clipboard text.
      // Never include raw exception strings in shared Worker logs.
      console.error(JSON.stringify({ event: "nexus_api_error", code: "internal_error" }));
      return json({ error: "internal_error" }, 500);
    }
  },
};
