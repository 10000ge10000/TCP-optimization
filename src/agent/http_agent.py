#!/usr/bin/env python3
"""Temporary, authenticated TCP-optimization HTTP agent."""

from __future__ import annotations

import collections
import hmac
import http.server
import ipaddress
import json
import math
import os
import signal
import socket
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlparse

TOKEN = os.environ["TCP_TUNE_TOKEN"]
SCRIPT = os.environ["TCP_TUNE_SCRIPT"]
STATE_DIR = os.environ["TCP_TUNE_STATE_DIR"]
SESSION_ID = os.environ["TCP_TUNE_SESSION_ID"]
IPERF_PORT = int(os.environ.get("TCP_TUNE_IPERF_PORT", "5201"))
AGENT_PORT = int(os.environ.get("TCP_TUNE_AGENT_PORT", "39188"))
TTL = int(os.environ.get("TCP_TUNE_SESSION_TTL", "1800"))
BODY_LIMIT = int(os.environ.get("TCP_TUNE_AGENT_BODY_LIMIT", "32768"))
MAX_CONCURRENCY = int(os.environ.get("TCP_TUNE_AGENT_MAX_CONCURRENCY", "8"))
ALLOW_QUERY_TOKEN = os.environ.get("TCP_TUNE_ALLOW_QUERY_TOKEN", "0") == "1"
ALLOWED_TEST_HOSTS = {
    item.strip() for item in os.environ.get("TCP_TUNE_AGENT_TEST_ALLOWLIST", "").split(",") if item.strip()
}
ALLOWED_HOST_HEADERS = {
    item.strip().lower() for item in os.environ.get("TCP_TUNE_AGENT_ALLOWED_HOSTS", "").split(",") if item.strip()
}
STARTED = time.time()
STOP_EVENT = threading.Event()
SERVER_INSTANCE = None
STATE_LOCK = threading.Lock()
PROCESS_LOCK = threading.Lock()
REQUEST_SLOTS = threading.BoundedSemaphore(max(1, min(MAX_CONCURRENCY, 64)))
TEST_SLOT = threading.BoundedSemaphore(1)
ACTIVE_PROCESSES = set()
PEER_IP = None
STATE = {
    "started_at": STARTED,
    "session_id": SESSION_ID,
    "peer_reports": collections.deque(maxlen=100),
    "events": collections.deque(maxlen=200),
}


def text(value, limit=256):
    cleaned = "".join(ch if ch >= " " and ch != "\x7f" else " " for ch in str(value or ""))
    return cleaned[:limit]


def client_ip(handler):
    value = handler.client_address[0]
    if value.startswith("::ffff:"):
        value = value[7:]
    return value


def token_valid(handler):
    supplied = handler.headers.get("X-TCP-Tune-Token", "")
    if not supplied:
        auth = handler.headers.get("Authorization", "")
        supplied = auth[7:].strip() if auth.startswith("Bearer ") else ""
    if not supplied and ALLOW_QUERY_TOKEN:
        supplied = parse_qs(urlparse(handler.path).query).get("token", [""])[0]
    return bool(supplied) and hmac.compare_digest(supplied, TOKEN)


def host_header_valid(handler):
    value = handler.headers.get("Host", "")
    if not value or len(value) > 320 or any(ord(ch) < 33 for ch in value):
        return False
    try:
        parsed = urlparse("//" + value)
        if parsed.port not in (None, AGENT_PORT):
            return False
        hostname = (parsed.hostname or "").lower()
    except ValueError:
        return False
    return bool(hostname) and (not ALLOWED_HOST_HEADERS or hostname in ALLOWED_HOST_HEADERS)


def write_json(handler, code, payload):
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    try:
        handler.wfile.write(body)
    except (BrokenPipeError, ConnectionResetError, socket.timeout):
        pass


def error(handler, status, code, message):
    write_json(handler, status, {"ok": False, "error": message, "error_code": code})


def read_json_body(handler):
    if handler.headers.get("Transfer-Encoding"):
        error(handler, 400, "unsupported_transfer_encoding", "chunked request bodies are not supported")
        return None
    raw_length = handler.headers.get("Content-Length")
    if raw_length is None:
        error(handler, 411, "length_required", "Content-Length is required")
        return None
    try:
        length = int(raw_length)
    except ValueError:
        error(handler, 400, "invalid_content_length", "invalid Content-Length")
        return None
    if length < 0 or length > BODY_LIMIT:
        error(handler, 413, "body_too_large", "request body too large")
        return None
    content_type = handler.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
    if length and content_type not in {"application/json", "application/problem+json"}:
        error(handler, 415, "unsupported_media_type", "application/json is required")
        return None
    raw = handler.rfile.read(length)
    if len(raw) != length:
        error(handler, 413, "body_too_large", "request body exceeds declared or allowed size")
        return None
    try:
        value = json.loads(raw.decode("utf-8")) if raw else {}
    except (UnicodeDecodeError, json.JSONDecodeError):
        error(handler, 400, "invalid_json", "invalid JSON body")
        return None
    if not isinstance(value, dict):
        error(handler, 400, "invalid_body", "request body must be an object")
        return None
    return value


def terminate_process(proc):
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run_cmd(args, timeout):
    proc = subprocess.Popen(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    with PROCESS_LOCK:
        ACTIVE_PROCESSES.add(proc)
    try:
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate_process(proc)
            stdout, stderr = proc.communicate()
            return {"code": 124, "stdout": stdout[-4000:], "stderr": (stderr + "\ncommand timed out")[-4000:]}
        return {"code": proc.returncode, "stdout": stdout[-4000:], "stderr": stderr[-4000:]}
    finally:
        with PROCESS_LOCK:
            ACTIVE_PROCESSES.discard(proc)


def terminate_active_processes():
    with PROCESS_LOCK:
        processes = list(ACTIVE_PROCESSES)
    for proc in processes:
        terminate_process(proc)


def strict_int(value, minimum, maximum):
    if isinstance(value, bool):
        return None
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    if str(number) != str(value).strip() and not isinstance(value, int):
        return None
    return number if minimum <= number <= maximum else None


def report_number(value, minimum, maximum, integer=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value) or value < minimum or value > maximum:
        return None
    if integer and int(value) != value:
        return None
    return int(value) if integer else value


def resolve_host(host):
    if not host or len(host) > 253 or host.startswith("-") or any(ord(ch) < 33 for ch in host):
        raise ValueError("invalid host")
    values = set()
    for item in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM):
        values.add(str(ipaddress.ip_address(item[4][0])))
    if not values:
        raise ValueError("host did not resolve")
    return values


def test_target_allowed(host):
    try:
        addresses = resolve_host(host)
    except (ValueError, socket.gaierror):
        return False
    explicit = set()
    for allowed in ALLOWED_TEST_HOSTS:
        try:
            explicit.update(resolve_host(allowed))
        except (ValueError, socket.gaierror):
            continue
    with STATE_LOCK:
        peer = PEER_IP
    permitted = explicit | ({peer} if peer else set())
    return bool(permitted) and addresses.issubset(permitted)


def append_event(event):
    with STATE_LOCK:
        STATE["events"].append(event)


def format_rate(value):
    try:
        bps = float(value or 0)
    except (TypeError, ValueError):
        return "未检测"
    return f"{bps / 1_000_000_000:.2f} Gbps" if bps >= 1_000_000_000 else f"{bps / 1_000_000:.1f} Mbps"


def event_text(event):
    stamp = time.strftime("%H:%M:%S", time.localtime(float(event.get("time", 0))))
    action = event.get("action")
    if action == "peer-report" and event.get("round") is not None:
        direction = "上传" if event.get("direction") == "upload" else "下载"
        return f"{stamp} 第 {event.get('round')} 轮{direction}：{format_rate(event.get('bits_per_second'))}，重传 {event.get('retransmits', '未检测')} 次"
    labels = {"peer-report": "客户端上报", "test": "服务端测速任务", "restore-defaults": "恢复默认值", "stop-request": "停止会话"}
    return f"{stamp} {labels.get(str(action), text(action))}"


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "tcp-tune-agent/0.2"

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, fmt, *args):
        return

    def _preflight(self):
        if time.time() - STARTED >= TTL or STOP_EVENT.is_set():
            error(self, 410, "session_expired", "session expired")
            return False
        if not host_header_valid(self):
            error(self, 400, "invalid_host_header", "invalid Host header")
            return False
        if not token_valid(self):
            error(self, 403, "invalid_token", "invalid token")
            return False
        return True

    def do_GET(self):
        if not REQUEST_SLOTS.acquire(blocking=False):
            error(self, 503, "busy", "agent concurrency limit reached")
            return
        try:
            if not self._preflight():
                return
            path = urlparse(self.path).path
            if path == "/state":
                with STATE_LOCK:
                    state = {"started_at": STARTED, "session_id": SESSION_ID, "peer_ip": PEER_IP}
                write_json(self, 200, {"ok": True, "iperf_port": IPERF_PORT, "state": state})
            elif path == "/events":
                with STATE_LOCK:
                    events = list(STATE["events"])
                    reports = list(STATE["peer_reports"])
                write_json(self, 200, {"ok": True, "events": events[-100:], "summaries": [event_text(v) for v in events[-30:]], "peer_reports": reports[-20:]})
            elif path == "/status":
                result = run_cmd([SCRIPT, "--json", "status"], 15)
                write_json(self, 200, {"ok": result["code"] == 0, "result": result})
            elif path == "/defaults":
                result = run_cmd([SCRIPT, "defaults-status"], 15)
                write_json(self, 200, {"ok": result["code"] == 0, "available": result["code"] == 0, "result": result})
            else:
                error(self, 404, "not_found", "not found")
        finally:
            REQUEST_SLOTS.release()

    def do_POST(self):
        if not REQUEST_SLOTS.acquire(blocking=False):
            error(self, 503, "busy", "agent concurrency limit reached")
            return
        try:
            if not self._preflight():
                return
            payload = read_json_body(self)
            if payload is None:
                return
            path = urlparse(self.path).path
            if path == "/report":
                self._report(payload)
            elif path == "/test":
                self._test(payload)
            elif path in {"/optimize", "/apply-profile", "/apply-buffers"}:
                error(self, 403, "server_read_only", "server is read-only")
            elif path == "/restore-defaults":
                result = run_cmd([SCRIPT, "restore-defaults"], 30)
                append_event({"time": time.time(), "action": "restore-defaults", "result": result["code"]})
                write_json(self, 200 if result["code"] == 0 else 500, {"ok": result["code"] == 0, "result": result})
            elif path == "/stop":
                append_event({"time": time.time(), "action": "stop-request"})
                write_json(self, 200, {"ok": True, "message": "agent stopping"})
                STOP_EVENT.set()
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                error(self, 404, "not_found", "not found")
        finally:
            REQUEST_SLOTS.release()

    def _report(self, payload):
        global PEER_IP
        allowed = {"role", "lan_ip", "os", "architecture", "round", "rounds", "objective", "direction", "retransmits", "bits_per_second", "first_second_bits_per_second", "stage", "result", "detail", "time", "target_retr"}
        unknown = set(payload) - allowed
        if unknown:
            error(self, 400, "unknown_fields", "unknown report fields")
            return
        enums = {
            "objective": {"retrans", "throughput", "startup"},
            "direction": {"upload", "download", "both"},
            "stage": {"preset-probe", "preset-apply", "rollback", "auto", "ai", "restore-defaults"},
            "result": {"running", "ok", "success", "rollback", "failed"},
        }
        for key, choices in enums.items():
            if key in payload and payload[key] not in choices:
                error(self, 400, "invalid_report_parameters", "invalid report parameters")
                return
        numeric_fields = {
            "round": (1, 100, True),
            "rounds": (1, 100, True),
            "retransmits": (0, 1_000_000_000, True),
            "bits_per_second": (0, 1_000_000_000_000_000, False),
            "first_second_bits_per_second": (0, 1_000_000_000_000_000, False),
            "time": (0, 4_102_444_800, False),
            "target_retr": (0, 1_000_000_000, True),
        }
        normalized = {}
        for key, value in payload.items():
            if key in numeric_fields:
                if value is None:
                    normalized[key] = None
                    continue
                converted = report_number(value, *numeric_fields[key])
                if converted is None:
                    error(self, 400, "invalid_report_parameters", "invalid report parameters")
                    return
                normalized[key] = converted
            else:
                normalized[key] = text(value, 512 if key == "detail" else 256)
        if normalized.get("lan_ip"):
            try:
                ipaddress.ip_address(normalized["lan_ip"])
            except ValueError:
                error(self, 400, "invalid_report_parameters", "invalid report parameters")
                return
        source = client_ip(self)
        with STATE_LOCK:
            if PEER_IP is None:
                PEER_IP = source
            elif PEER_IP != source:
                error(self, 403, "peer_mismatch", "session is paired with another client")
                return
            report = {"time": time.time(), "payload": normalized}
            STATE["peer_reports"].append(report)
            event = {"time": time.time(), "action": "peer-report"}
            for key in allowed:
                if key in normalized:
                    event[key] = normalized[key]
            STATE["events"].append(event)
        write_json(self, 200, {"ok": True})

    def _test(self, payload):
        if set(payload) - {"host", "port", "seconds", "direction"}:
            error(self, 400, "unknown_fields", "unknown test fields")
            return
        host = str(payload.get("host", "")).strip()
        port = strict_int(payload.get("port", IPERF_PORT), 1, 65535)
        seconds = strict_int(payload.get("seconds", 10), 1, 60)
        direction = payload.get("direction", "download")
        if port is None or seconds is None or direction not in {"download", "upload"}:
            error(self, 400, "invalid_test_parameters", "invalid test parameters")
            return
        if not test_target_allowed(host):
            error(self, 403, "test_target_denied", "test target is not the paired client or allowlisted")
            return
        if not TEST_SLOT.acquire(blocking=False):
            error(self, 429, "test_busy", "another test is already running")
            return
        try:
            reverse = "1" if direction == "download" else "0"
            result = run_cmd([SCRIPT, "_iperf-json", host, str(port), reverse, str(seconds)], seconds + 15)
            append_event({"time": time.time(), "action": "test", "direction": direction, "result": result["code"]})
            write_json(self, 200 if result["code"] == 0 else 502, {"ok": result["code"] == 0, "result": result})
        finally:
            TEST_SLOT.release()


class DualStackThreadingHTTPServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def create_server():
    try:
        return DualStackThreadingHTTPServer(("::", AGENT_PORT), Handler)
    except OSError:
        return http.server.ThreadingHTTPServer(("0.0.0.0", AGENT_PORT), Handler)


def shutdown_signal(signum, frame):
    del signum, frame
    STOP_EVENT.set()
    if SERVER_INSTANCE is not None:
        threading.Thread(target=SERVER_INSTANCE.shutdown, daemon=True).start()


def ttl_watchdog(server):
    if not STOP_EVENT.wait(max(0, STARTED + TTL - time.time())):
        STOP_EVENT.set()
        server.shutdown()


if __name__ == "__main__":
    os.umask(0o077)
    server = create_server()
    SERVER_INSTANCE = server
    signal.signal(signal.SIGTERM, shutdown_signal)
    signal.signal(signal.SIGINT, shutdown_signal)
    watcher = threading.Thread(target=ttl_watchdog, args=(server,), daemon=True)
    watcher.start()
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        STOP_EVENT.set()
        server.server_close()
        terminate_active_processes()
        subprocess.Popen(
            ["/bin/sh", SCRIPT, "stop-agent", "--session", SESSION_ID],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
