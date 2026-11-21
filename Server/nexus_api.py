"""Nexus statistics API. Run behind a TLS reverse proxy with NEXUS_API_TOKEN set."""

import json
import os
import re
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def open_database(path):
    connection = sqlite3.connect(path, timeout=10, check_same_thread=False)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("""
        CREATE TABLE IF NOT EXISTS input_events (
            device_id TEXT NOT NULL,
            event_id INTEGER NOT NULL,
            time_ms INTEGER NOT NULL,
            category TEXT NOT NULL,
            name TEXT NOT NULL,
            count INTEGER NOT NULL CHECK(count > 0),
            PRIMARY KEY(device_id, event_id)
        )
    """)
    connection.execute("CREATE INDEX IF NOT EXISTS input_events_range ON input_events(time_ms, device_id)")
    return connection


def valid_event_name(category, name):
    names = {
        "ordinary": {"character_total"},
        "keyboard": {"escape", "delete", "forward_delete", "return", "tab", "space", "left", "right", "up", "down", "home", "end", "page_up", "page_down"},
        "modifier": {"left_command", "right_command", "left_option", "right_option", "left_control", "right_control", "left_shift", "right_shift", "caps_lock", "fn"},
        "shortcut": {"command_c", "command_v", "command_x", "command_z", "command_shift_z", "command_tab", "command_space", "command_q", "control_command_q", "command_escape", "command_option_escape"},
        "mouse": {"mouse_left", "mouse_right", "mouse_middle", "mouse_back", "mouse_forward"},
        "scroll": {"scroll_up", "scroll_down", "scroll_left", "scroll_right"},
        "system": {"volume_up", "volume_down", "brightness_up", "brightness_down", "mute", "play_pause", "next", "previous", "fast_forward", "rewind", "keyboard_light_up", "keyboard_light_down", "keyboard_light_toggle", "caps_lock_on", "caps_lock_off"},
    }
    return name in names.get(category, set()) or (category == "keyboard" and re.fullmatch(r"f(?:[1-9]|1\d|2[0-4])", name)) or (category == "mouse" and re.fullmatch(r"mouse_extra_\d{1,2}", name)) or (category == "shortcut" and re.fullmatch(r"fn_f(?:[1-9]|1\d|2[0-4])", name))


class NexusAPI(BaseHTTPRequestHandler):
    server_version = "NexusAPI/1"

    def do_GET(self):
        if not self.authorized():
            return
        path = urlsplit(self.path)
        if path.path == "/api/nexus/v1/me":
            self.respond(200, {"authenticated": True})
        elif path.path == "/api/nexus/v1/statistics/summary":
            bounds = self.bounds(path.query)
            if bounds is None:
                return
            start, end, device = bounds
            with self.server.database_lock:
                rows = self.server.database.execute(
                    "SELECT category, name, SUM(count) FROM input_events WHERE time_ms >= ? AND time_ms < ? AND (? IS NULL OR device_id = ?) GROUP BY category, name ORDER BY category, name",
                    (start, end, device, device),
                ).fetchall()
            self.respond(200, {"start_ms": start, "end_ms": end, "statistics": [{"category": row[0], "name": row[1], "count": row[2]} for row in rows]})
        elif path.path == "/api/nexus/v1/statistics/events":
            bounds = self.bounds(path.query)
            if bounds is None:
                return
            start, end, device = bounds
            try:
                offset = int(parse_qs(path.query).get("offset", ["0"])[0])
                if offset < 0 or offset > 1_000_000:
                    raise ValueError()
            except ValueError:
                self.respond(400, {"error": "invalid_offset"})
                return
            with self.server.database_lock:
                rows = self.server.database.execute(
                    "SELECT device_id, event_id, time_ms, category, name, count FROM input_events WHERE time_ms >= ? AND time_ms < ? AND (? IS NULL OR device_id = ?) ORDER BY time_ms, device_id, event_id LIMIT 1000 OFFSET ?",
                    (start, end, device, device, offset),
                ).fetchall()
            self.respond(200, {"events": [dict(zip(("device_id", "id", "time_ms", "category", "name", "count"), row)) for row in rows], "next_offset": offset + 1000 if len(rows) == 1000 else None})
        else:
            self.respond(404, {"error": "not_found"})

    def do_POST(self):
        if not self.authorized():
            return
        if urlsplit(self.path).path != "/api/nexus/v1/statistics/events":
            self.respond(404, {"error": "not_found"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 1 or size > 1_000_000:
                raise ValueError("invalid body size")
            body = json.loads(self.rfile.read(size))
            device = body["device_id"]
            events = body["events"]
            if body.get("schema_version") != 1 or not isinstance(device, str) or len(device) > 80 or not device:
                raise ValueError("invalid batch")
            if not isinstance(events, list) or len(events) > 500:
                raise ValueError("invalid event count")
            records = []
            for event in events:
                event_id, time_ms, count = (event[key] for key in ("id", "time_ms", "count"))
                category, name = (event[key] for key in ("category", "name"))
                if not all(type(value) is int for value in (event_id, time_ms, count)) or event_id < 0 or time_ms < 0 or not 0 < count <= 1_000_000:
                    raise ValueError("invalid event numbers")
                if not isinstance(name, str) or not valid_event_name(category, name):
                    raise ValueError("invalid category or name")
                records.append((device, event_id, time_ms, category, name, count))
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            self.respond(400, {"error": "invalid_request"})
            return
        with self.server.database_lock:
            with self.server.database:
                self.server.database.executemany("INSERT INTO input_events VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(device_id, event_id) DO NOTHING", records)
        self.respond(200, {"accepted_ids": [event[1] for event in records]})

    def do_DELETE(self):
        if not self.authorized():
            return
        if urlsplit(self.path).path != "/api/nexus/v1/statistics/events":
            self.respond(404, {"error": "not_found"})
            return
        device = parse_qs(urlsplit(self.path).query).get("device_id", [None])[0]
        if not device:
            self.respond(400, {"error": "device_id_required"})
            return
        with self.server.database_lock:
            with self.server.database:
                count = self.server.database.execute("DELETE FROM input_events WHERE device_id = ?", (device,)).rowcount
        self.respond(200, {"deleted": count})

    def authorized(self):
        expected = self.server.token
        import hmac
        if expected and hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + expected):
            return True
        self.respond(401, {"error": "unauthorized"})
        return False

    def bounds(self, query):
        try:
            parameters = parse_qs(query)
            start = int(parameters["start_ms"][0])
            end = int(parameters["end_ms"][0])
            if start < 0 or end <= start:
                raise ValueError()
            return start, end, parameters.get("device_id", [None])[0]
        except (ValueError, KeyError, IndexError):
            self.respond(400, {"error": "invalid_range"})
            return None

    def respond(self, status, value):
        payload = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def serve(address="127.0.0.1", port=8765, database_path="nexus-api.sqlite", token=None):
    from threading import Lock
    if not token:
        raise ValueError("NEXUS_API_TOKEN is required")
    server = ThreadingHTTPServer((address, port), NexusAPI)
    server.database = open_database(database_path)
    server.database_lock = Lock()
    server.token = token
    return server


if __name__ == "__main__":
    api = serve(
        address=os.environ.get("NEXUS_API_HOST", "127.0.0.1"),
        port=int(os.environ.get("NEXUS_API_PORT", "8765")),
        database_path=os.environ.get("NEXUS_API_DATABASE", "nexus-api.sqlite"),
        token=os.environ.get("NEXUS_API_TOKEN"),
    )
    api.serve_forever()
