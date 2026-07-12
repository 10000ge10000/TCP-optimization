import http.client
import json
import os
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
AGENT = ROOT / "src" / "agent" / "http_agent.py"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class AgentIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.port = free_port()
        self.token = "a" * 64
        fake = Path(self.temp.name) / "fake-script.sh"
        fake.write_text("#!/bin/sh\ncase \"${1:-}\" in _iperf-json) printf '{\"end\":{}}' ;; status) printf '{}' ;; defaults-status) exit 1 ;; stop-agent) exit 0 ;; restore-defaults) exit 0 ;; esac\n", encoding="utf-8")
        fake.chmod(0o700)
        env = os.environ.copy()
        env.update({
            "TCP_TUNE_TOKEN": self.token,
            "TCP_TUNE_SCRIPT": str(fake),
            "TCP_TUNE_STATE_DIR": self.temp.name,
            "TCP_TUNE_SESSION_ID": "test-session",
            "TCP_TUNE_AGENT_PORT": str(self.port),
            "TCP_TUNE_IPERF_PORT": "5201",
            "TCP_TUNE_SESSION_TTL": "3",
            "TCP_TUNE_AGENT_BODY_LIMIT": "32768",
            "TCP_TUNE_AGENT_MAX_CONCURRENCY": "2",
            "TCP_TUNE_ALLOW_QUERY_TOKEN": "0",
        })
        self.proc = subprocess.Popen([os.environ.get("PYTHON", "python3"), str(AGENT)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                status, _ = self.request("GET", "/state")
                if status == 200:
                    return
            except OSError:
                time.sleep(0.05)
        self.fail("agent did not start")

    def tearDown(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=2)
        if self.proc.stdout:
            self.proc.stdout.close()
        if self.proc.stderr:
            self.proc.stderr.close()
        self.temp.cleanup()

    def request(self, method, path, body=None, token=True):
        headers = {"Host": f"127.0.0.1:{self.port}"}
        if token:
            headers["X-TCP-Tune-Token"] = self.token
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
            headers["Content-Length"] = str(len(data))
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request(method, path, body=data, headers=headers)
        response = connection.getresponse()
        payload = response.read()
        connection.close()
        return response.status, json.loads(payload)

    def test_header_auth_and_query_token_disabled(self):
        self.assertEqual(self.request("GET", "/state")[0], 200)
        self.assertEqual(self.request("GET", f"/state?token={self.token}", token=False)[0], 403)

    def test_read_only_endpoints_remain_blocked(self):
        status, payload = self.request("POST", "/apply-buffers", {})
        self.assertEqual(status, 403)
        self.assertEqual(payload["error_code"], "server_read_only")

    def test_pairing_and_test_target_policy(self):
        self.assertEqual(self.request("POST", "/report", {"role": "test", "lan_ip": "127.0.0.1"})[0], 200)
        self.assertEqual(self.request("POST", "/test", {"host": "127.0.0.1", "port": 5201, "seconds": 1, "direction": "download"})[0], 200)
        self.assertEqual(self.request("POST", "/test", {"host": "192.0.2.10", "port": 5201, "seconds": 1, "direction": "download"})[0], 403)

    def test_unknown_report_fields_are_rejected(self):
        status, payload = self.request("POST", "/report", {"role": "test", "unexpected": "x"})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error_code"], "unknown_fields")

    def test_invalid_report_enums_and_numbers_are_rejected(self):
        invalid = (
            {"role": "test", "direction": "sideways"},
            {"role": "test", "objective": "fastest"},
            {"role": "test", "bits_per_second": "1000"},
            {"role": "test", "retransmits": -1},
            {"role": "test", "round": 1.5},
            {"role": "test", "lan_ip": "not-an-ip"},
        )
        for body in invalid:
            with self.subTest(body=body):
                status, payload = self.request("POST", "/report", body)
                self.assertEqual(status, 400)
                self.assertEqual(payload["error_code"], "invalid_report_parameters")

    def test_zero_metrics_remain_numeric_and_missing_metrics_remain_absent(self):
        body = {"role": "test", "direction": "upload", "bits_per_second": 0, "retransmits": 0}
        self.assertEqual(self.request("POST", "/report", body)[0], 200)
        status, payload = self.request("GET", "/events")
        self.assertEqual(status, 200)
        stored = payload["peer_reports"][-1]["payload"]
        self.assertEqual(stored["bits_per_second"], 0)
        self.assertEqual(stored["retransmits"], 0)
        self.assertNotIn("first_second_bits_per_second", stored)

    def test_null_metrics_are_accepted_as_unknown(self):
        body = {"role": "windows-client", "direction": "upload", "bits_per_second": 1000, "retransmits": None, "first_second_bits_per_second": None}
        self.assertEqual(self.request("POST", "/report", body)[0], 200)
        _, payload = self.request("GET", "/events")
        stored = payload["peer_reports"][-1]["payload"]
        self.assertIsNone(stored["retransmits"])
        self.assertIsNone(stored["first_second_bits_per_second"])

    def test_oversized_body_is_rejected_before_parsing(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.putrequest("POST", "/report")
        connection.putheader("Host", f"127.0.0.1:{self.port}")
        connection.putheader("X-TCP-Tune-Token", self.token)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Content-Length", "32769")
        connection.endheaders()
        response = connection.getresponse()
        payload = json.loads(response.read())
        connection.close()
        self.assertEqual(response.status, 413)
        self.assertEqual(payload["error_code"], "body_too_large")

    def test_ttl_stops_agent(self):
        self.proc.wait(timeout=6)
        self.assertIsNotNone(self.proc.returncode)


if __name__ == "__main__":
    unittest.main()
