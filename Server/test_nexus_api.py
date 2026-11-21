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
