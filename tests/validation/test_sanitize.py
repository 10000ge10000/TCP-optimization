import json
import os
import subprocess
import sys
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import sanitize  # noqa: E402


class SanitizeTests(unittest.TestCase):
    def test_recursive_secret_user_host_and_ip_redaction(self):
        source = {
            "token": "real-token",
            "headers": {"Authorization": "Bearer secret", "Cookie": "sid=secret"},
            "username": "admin",
            "hostname": "production-vps",
            "session_id": "session-real",
            "timestamp": "2026-07-12T12:34:56Z",
            "server_ip": "203.0.113.88",
            "message": "peer 10.0.0.4 and 2001:db8:abcd::1",
        }
        result = sanitize.sanitize(source)
        self.assertEqual(result["token"], "<redacted>")
        self.assertEqual(result["headers"]["Authorization"], "<redacted>")
        self.assertEqual(result["headers"]["Cookie"], "<redacted>")
        self.assertEqual(result["username"], "redacted-user")
        self.assertEqual(result["hostname"], "host.example.invalid")
        self.assertEqual(result["session_id"], "session-redacted")
        self.assertEqual(result["timestamp"], "1970-01-01T00:00:00Z")
        self.assertEqual(result["server_ip"], "192.0.2.1")
        self.assertNotIn("10.0.0.4", result["message"])
        self.assertNotIn("2001:db8:abcd", result["message"])

    def test_embedded_headers_query_credentials_and_addresses(self):
        text = (
            "Authorization: Bearer abc.def\n"
            "X-TCP-Tune-Token: top-secret\n"
            "Cookie: sid=abc\n"
            "https://admin:password@198.51.100.9/test?token=abc"
        )
        result = sanitize.sanitize_string(text)
        self.assertNotIn("abc.def", result)
        self.assertNotIn("top-secret", result)
        self.assertNotIn("sid=abc", result)
        self.assertNotIn("admin:password", result)
        self.assertNotIn("198.51.100.9", result)
        self.assertIn("192.0.2.1", result)

    def test_jsonl_round_trip_remains_valid_json(self):
        source = '{"remote_addr":"198.51.100.42","token":"abc"}\n{"username":"root"}\n'
        payload, is_jsonl = sanitize.load_payload(source, "jsonl")
        output = sanitize.dump_payload(payload, is_jsonl)
        rows = [json.loads(line) for line in output.splitlines()]
        self.assertEqual(rows[0]["remote_addr"], "192.0.2.1")
        self.assertEqual(rows[1]["username"], "redacted-user")

    def test_cli_auto_detects_json(self):
        process = subprocess.run(
            [sys.executable, os.path.join(HERE, "sanitize.py")],
            input='{"client_ip":"192.168.1.2","api_key":"secret"}',
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(process.stdout)
        self.assertEqual(result["client_ip"], "192.0.2.1")
        self.assertEqual(result["api_key"], "<redacted>")


if __name__ == "__main__":
    unittest.main()
