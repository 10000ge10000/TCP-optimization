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
        # _iperf-json 回显收到的 host，供“测试目标已钉住”用例断言。
        fake.write_text("#!/bin/sh\ncase \"${1:-}\" in _iperf-json) printf '{\"target\":\"%s\",\"end\":{}}' \"$2\" ;; status) printf '{}' ;; defaults-status) exit 1 ;; stop-agent) exit 0 ;; restore-defaults) exit 0 ;; esac\n", encoding="utf-8")
        # The downloaded single-file script is commonly invoked through `sh`
        # and may not carry its executable bit. The Agent must support that.
        fake.chmod(0o600)
        self.script = fake
        self.extra_procs = []
        self.proc = self.start_agent(self.port)

    def start_agent(self, port, extra_env=None):
        env = os.environ.copy()
        env.update({
            "TCP_TUNE_TOKEN": self.token,
            "TCP_TUNE_SCRIPT": str(self.script),
            "TCP_TUNE_STATE_DIR": self.temp.name,
            "TCP_TUNE_SESSION_ID": "test-session",
            "TCP_TUNE_AGENT_PORT": str(port),
            "TCP_TUNE_IPERF_PORT": "5201",
            "TCP_TUNE_SESSION_TTL": "3",
            "TCP_TUNE_AGENT_BODY_LIMIT": "32768",
            "TCP_TUNE_AGENT_MAX_CONCURRENCY": "2",
            "TCP_TUNE_ALLOW_QUERY_TOKEN": "0",
        })
        env.update(extra_env or {})
        proc = subprocess.Popen([os.environ.get("PYTHON", "python3"), str(AGENT)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if port != self.port:
            self.extra_procs.append(proc)
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                status, _ = self.request("GET", "/state", port=port)
                if status == 200:
                    return proc
            except OSError:
                time.sleep(0.05)
        self.fail(f"agent on port {port} did not start")

    def stop_proc(self, proc):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
        if proc.stdout:
            proc.stdout.close()
        if proc.stderr:
            proc.stderr.close()

    def tearDown(self):
        for proc in [self.proc, *self.extra_procs]:
            self.stop_proc(proc)
        self.temp.cleanup()

    def request(self, method, path, body=None, token=True, port=None):
        port = port or self.port
        headers = {"Host": f"127.0.0.1:{port}"}
        if token:
            headers["X-TCP-Tune-Token"] = self.token
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
            headers["Content-Length"] = str(len(data))
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        connection.request(method, path, body=data, headers=headers)
        response = connection.getresponse()
        payload = response.read()
        connection.close()
        return response.status, json.loads(payload)

    def test_header_auth_and_query_token_disabled(self):
        self.assertEqual(self.request("GET", "/state")[0], 200)
        self.assertEqual(self.request("GET", f"/state?token={self.token}", token=False)[0], 403)

    def test_missing_and_wrong_header_token_are_rejected(self):
        self.assertEqual(self.request("GET", "/state", token=False)[0], 403)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request("GET", "/state", headers={
            "Host": f"127.0.0.1:{self.port}",
            "X-TCP-Tune-Token": "b" * 64,
        })
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(response.status, 403)

    def test_non_ascii_token_is_rejected_not_crashed(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.putrequest("GET", "/state", skip_host=True)
        connection.putheader("Host", f"127.0.0.1:{self.port}")
        # latin-1 头部注入非 ASCII 字节，历史实现会在 compare_digest 抛 TypeError。
        connection.putheader("X-TCP-Tune-Token", "秘密令牌".encode("utf-8"))
        connection.endheaders()
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(response.status, 403)
        # Agent 必须仍然存活并能处理后续合法请求。
        self.assertEqual(self.request("GET", "/state")[0], 200)

    def test_read_only_endpoints_remain_blocked(self):
        status, payload = self.request("POST", "/apply-buffers", {})
        self.assertEqual(status, 403)
        self.assertEqual(payload["error_code"], "server_read_only")

    def test_fixed_script_commands_do_not_require_executable_bit(self):
        status, payload = self.request("GET", "/status")
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])

    def test_control_endpoints_reject_unknown_body_fields(self):
        for path in ("/restore-defaults", "/stop"):
            with self.subTest(path=path):
                status, payload = self.request("POST", path, {"sysctl": {"net.ipv4.ip_forward": 1}})
                self.assertEqual(status, 400)
                self.assertEqual(payload["error_code"], "unknown_fields")

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

    def test_slow_body_does_not_hold_concurrency_slot(self):
        # 并发上限为 2：一个慢速 POST 在读 body 期间不得占用额度，
        # 否则少量慢速连接即可让合法请求持续收到 503。
        slow = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        slow.putrequest("POST", "/report")
        slow.putheader("Host", f"127.0.0.1:{self.port}")
        slow.putheader("X-TCP-Tune-Token", self.token)
        slow.putheader("Content-Type", "application/json")
        slow.putheader("Content-Length", "512")
        slow.endheaders()
        try:
            slow.send(b'{"role":"t')
            for _ in range(3):
                self.assertEqual(self.request("GET", "/state")[0], 200)
        finally:
            slow.close()

    def test_test_target_is_pinned_to_validated_address(self):
        self.assertEqual(self.request("POST", "/report", {"role": "test", "lan_ip": "127.0.0.1"})[0], 200)
        resolved = {item[4][0] for item in socket.getaddrinfo("localhost", None, type=socket.SOCK_STREAM)}
        status, payload = self.request("POST", "/test", {"host": "localhost", "port": 5201, "seconds": 1, "direction": "download"})
        if resolved - {"127.0.0.1"}:
            # localhost 还解析到 ::1 等地址（GitHub runner 即如此）：不在许可集内必须失败关闭。
            self.assertEqual(status, 403)
            self.assertEqual(payload["error_code"], "test_target_denied")
            return
        # localhost 只解析到已配对地址时必须放行，且传给 iperf3 的是校验出的 IP 而非主机名。
        self.assertEqual(status, 200)
        forwarded = json.loads(payload["result"]["stdout"])["target"]
        self.assertEqual(forwarded, "127.0.0.1")

    def test_allowlisted_hostname_is_forwarded_as_resolved_ip(self):
        # 显式 allowlist 覆盖 localhost 的全部解析地址，因此单栈/双栈环境都会放行；
        # 断言重点是转发给 iperf3 的必须是 IP 字面量，而不是可被重绑定的主机名。
        port = free_port()
        self.start_agent(port, {"TCP_TUNE_AGENT_TEST_ALLOWLIST": "localhost"})
        self.assertEqual(self.request("POST", "/report", {"role": "test", "lan_ip": "127.0.0.1"}, port=port)[0], 200)
        status, payload = self.request("POST", "/test", {"host": "localhost", "port": 5201, "seconds": 1, "direction": "download"}, port=port)
        self.assertEqual(status, 200)
        forwarded = json.loads(payload["result"]["stdout"])["target"]
        self.assertNotEqual(forwarded, "localhost")
        self.assertIn(forwarded, {item[4][0] for item in socket.getaddrinfo("localhost", None, type=socket.SOCK_STREAM)})

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
