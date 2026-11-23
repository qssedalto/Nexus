import contextlib
import io
import json
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from nexus_api import serve


class NexusAPITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.server = serve(port=0, database_path=str(Path(self.directory.name) / "api.sqlite"), token="test-secret")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server.database.close()
        self.directory.cleanup()

    def request(self, path, method="GET", body=None, token="test-secret"):
        request = Request(
            f"http://127.0.0.1:{self.server.server_port}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        with urlopen(request, timeout=5) as response:
            return json.load(response)

    def test_http_request_logging_does_not_write_sensitive_query_text(self):
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            self.request("/api/nexus/v1/me?clipboard_text=PRIVATE_SECRET")
        self.assertNotIn("PRIVATE_SECRET", captured.getvalue())

    def test_auth_capability_handshake(self):
        hello = self.request("/api/nexus/v1/me")
        self.assertTrue(hello["authenticated"])
        self.assertEqual(hello["schema_version"], 1)
        self.assertIn("statistics.events", hello["capabilities"])
        self.assertIn("statistics.monotonic_aggregates", hello["capabilities"])
        self.assertIn("operations.events", hello["capabilities"])
        self.assertIn("operations.restore", hello["capabilities"])

    def test_retry_and_millisecond_range(self):
        body = {"schema_version": 1, "device_id": "device-a", "events": [
            {"id": 1, "time_ms": 1000, "category": "keyboard", "name": "escape", "count": 2},
            {"id": 2, "time_ms": 1001, "category": "mouse", "name": "mouse_left", "count": 3},
        ]}
        self.assertEqual(self.request("/api/nexus/v1/statistics/events", "POST", body)["accepted_ids"], [1, 2])
        self.request("/api/nexus/v1/statistics/events", "POST", body)
        first = self.request("/api/nexus/v1/statistics/summary?start_ms=1000&end_ms=1001")
        self.assertEqual(first["statistics"], [{"category": "keyboard", "name": "escape", "count": 2}])
        full = self.request("/api/nexus/v1/statistics/summary?start_ms=1000&end_ms=1002")
        self.assertEqual(sum(item["count"] for item in full["statistics"]), 5)
        self.assertEqual(len(self.request("/api/nexus/v1/statistics/events?start_ms=0&end_ms=2000")["events"]), 2)


    def test_physical_key_and_general_shortcut_protocol(self):
        endpoint = "/api/nexus/v1/statistics/events"
        accepted = [
            ("ordinary", "character_total"), ("ordinary", "key_a"),
            ("ordinary", "shift_key_1"), ("ordinary", "key_semicolon"),
            ("ordinary", "key_keypad_9"), ("ordinary", "shift_key_quote"),
            ("keyboard", "f24"), ("keyboard", "num_lock"),
            ("shortcut", "control_shift_a"), ("shortcut", "command_shift_4"),
            ("shortcut", "option_command_semicolon"), ("shortcut", "command_keypad_3"),
            ("shortcut", "command_fn_f13"), ("shortcut", "fn_f1"),
            ("system", "spotlight_search"), ("system", "power"),
        ]
        events = [
            {"id": 100 + i, "time_ms": 5000 + i, "category": category,
             "name": name, "count": 1}
            for i, (category, name) in enumerate(accepted)
        ]
        self.assertEqual(self.request(endpoint, "POST", {
            "schema_version": 1, "device_id": "general-keys", "events": events
        })["accepted_ids"], [event["id"] for event in events])
        summary = self.request("/api/nexus/v1/statistics/summary?start_ms=5000&end_ms=6000")
        self.assertEqual(sum(row["count"] for row in summary["statistics"]), len(events))
        rejected = [
            ("ordinary", "typed_password"), ("ordinary", "key_password"),
            ("ordinary", "key_keypad_password"),
            ("shortcut", "shift_a"), ("shortcut", "command_command_c"),
            ("shortcut", "command_private_text"),
            ("system", "unrecognized_system_key_99"),
            ("mouse", "mouse_extra_999"), ("ordinary", "key_a\\n"),
        ]
        for category, name in rejected:
            with self.subTest(category=category, name=name):
                with self.assertRaises(HTTPError) as failure:
                    self.request(endpoint, "POST", {
                        "schema_version": 1, "device_id": "invalid-keys",
                        "events": [{"id": 1, "time_ms": 9000,
                                    "category": category, "name": name, "count": 1}],
                    })
                self.assertEqual(failure.exception.code, 400)

    def test_lost_ack_retry_updates_aggregate_without_double_count(self):
        endpoint = "/api/nexus/v1/statistics/events"
        old = {
            "schema_version": 1, "device_id": "device-aggregate",
            "events": [{"id": 42, "time_ms": 3600000,
                        "category": "ordinary", "name": "character_total",
                        "count": 2}],
        }
        # The first server write succeeds but the client never gets its ACK.
        self.assertEqual(self.request(endpoint, "POST", old)["accepted_ids"], [42])
        # Another keypress joins that hourly bucket before the retry.
        newer = {
            **old,
            "events": [{**old["events"][0], "count": 3, "time_ms": 3600500}],
        }
        self.assertEqual(self.request(endpoint, "POST", newer)["accepted_ids"], [42])
        # An out-of-order stale retry must never reduce the server count.
        self.assertEqual(self.request(endpoint, "POST", old)["accepted_ids"], [42])
        restored = self.request(endpoint + "?start_ms=3600000&end_ms=3601000")
        self.assertEqual(len(restored["events"]), 1)
        self.assertEqual(restored["events"][0]["count"], 3)
        self.assertEqual(restored["events"][0]["time_ms"], 3600000)
        summary = self.request(
            "/api/nexus/v1/statistics/summary?start_ms=3600000&end_ms=7200000"
        )
        self.assertEqual(summary["statistics"], [
            {"category": "ordinary", "name": "character_total", "count": 3}
        ])

    def test_authentication_and_invalid_data(self):
        with self.assertRaises(HTTPError) as unauthorized:
            self.request("/api/nexus/v1/me", token="wrong")
        self.assertEqual(unauthorized.exception.code, 401)
        with self.assertRaises(HTTPError) as invalid:
            self.request("/api/nexus/v1/statistics/events", "POST", {"schema_version": 1, "device_id": "a", "events": [{"id": 1, "time_ms": 1, "category": "ordinary", "name": "typed_password", "count": 1}]})
        self.assertEqual(invalid.exception.code, 400)


    def test_operation_sync_is_idempotent_and_does_not_invent_paths(self):
        record = {
            "id": "c52cbbaa-b888-4473-b66b-10869e62daf9",
            "type": "image_copy",
            "event_time_ms": None,
            "detected_time_ms": 7001,
            "completed_time_ms": None,
            "source_application": None,
            "detection_method": "clipboard_type",
            "status": "clipboard_detected",
            "target": None,
            "duration_ms": None,
            "clipboard_text": None,
            "items": [{
                "position": 0,
                "name": "Clipboard image",
                "source": None,
                "extension": None,
                "kind": "image",
                "size": None,
            }],
        }
        batch = {"schema_version": 1, "device_id": "device-1", "operations": [record]}
        endpoint = "/api/nexus/v1/operations/events"
        self.assertEqual(self.request(endpoint, "POST", batch)["accepted_ids"], [record["id"]])
        self.assertEqual(self.request(endpoint, "POST", batch)["accepted_ids"], [record["id"]])
        record["items"][0]["size"] = 501
        self.assertEqual(self.request(endpoint, "POST", batch)["accepted_ids"], [record["id"]])
        page = self.request(endpoint + "?start_ms=7001&end_ms=7002")
        self.assertEqual(len(page["operations"]), 1)
        self.assertEqual(page["operations"][0]["operation"]["items"][0]["source"], None)
        self.assertEqual(page["operations"][0]["operation"]["items"][0]["size"], 501)
        self.assertEqual(self.request(endpoint + "?start_ms=7002&end_ms=7003")["operations"], [])
        self.assertEqual(self.request(endpoint + "?device_id=device-1", method="DELETE")["deleted"], 1)
        self.assertEqual(self.request(endpoint + "?start_ms=0&end_ms=9000")["operations"], [])

    def test_operation_sync_validates_payload_and_authorization(self):
        endpoint = "/api/nexus/v1/operations/events"
        op = {
            "id": "48a989b2-beaa-4acc-8124-d8968a68421b",
            "type": "text_copy",
            "detected_time_ms": 1000,
            "detection_method": "clipboard",
            "status": "clipboard_detected",
            "items": [{"position": 0, "name": "Text", "kind": "text", "size": 100}],
        }
        body = {"schema_version": 1, "device_id": "d", "operations": [op]}
        with self.assertRaises(HTTPError) as bad_auth:
            self.request(endpoint, "POST", body, token="bad")
        self.assertEqual(bad_auth.exception.code, 401)
        with self.assertRaises(HTTPError) as invalid:
            bad_op = {**op, "items": [{**op["items"][0], "position": 99}]}
            self.request(endpoint, "POST", {**body, "operations": [bad_op]})
        self.assertEqual(invalid.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
