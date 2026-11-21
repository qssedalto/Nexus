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


if __name__ == "__main__":
    unittest.main()
