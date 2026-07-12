#!/usr/bin/env python3
"""Sanitize JSON or JSONL validation artifacts using deterministic placeholders."""

import argparse
import ipaddress
import json
import re
import sys


SECRET_KEYS = {
    "authorization",
    "cookie",
    "set-cookie",
    "token",
    "access_token",
    "api_key",
    "apikey",
    "password",
    "secret",
}
USER_KEYS = {"user", "username", "login", "account"}
SESSION_KEYS = {"session", "session_id", "sessionid", "request_id", "trace_id"}
TIME_KEYS = {"time", "timestamp", "started_at", "finished_at", "created_at", "updated_at"}
HOST_KEYS = {
    "host",
    "hostname",
    "server_name",
    "server_host",
    "client_host",
    "server_ip",
    "client_ip",
    "remote_addr",
    "local_addr",
}

BEARER_RE = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+")
QUERY_SECRET_RE = re.compile(
    r"(?i)(\b(?:token|access_token|api[_-]?key|password|secret)=)[^&\s\"']+"
)
COOKIE_RE = re.compile(r"(?i)(\b(?:cookie|set-cookie)\s*:\s*)[^\r\n]+")
TOKEN_HEADER_RE = re.compile(r"(?i)(\bx-tcp-tune-token\s*:\s*)[^\r\n]+")
URL_CREDENTIAL_RE = re.compile(r"(?i)(https?://)[^/@\s:]+(?::[^/@\s]*)?@")
IP_CANDIDATE_RE = re.compile(
    r"(?<![0-9A-Fa-f:.])(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f]*:[0-9A-Fa-f:.]+)(?![0-9A-Fa-f:.])"
)


def _replace_ip(match):
    candidate = match.group(0)
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        return candidate
    return "192.0.2.1" if address.version == 4 else "2001:db8::1"


def sanitize_string(value):
    value = BEARER_RE.sub("Bearer <redacted-token>", value)
    value = QUERY_SECRET_RE.sub(lambda match: match.group(1) + "<redacted>", value)
    value = COOKIE_RE.sub(lambda match: match.group(1) + "<redacted>", value)
    value = TOKEN_HEADER_RE.sub(lambda match: match.group(1) + "<redacted>", value)
    value = URL_CREDENTIAL_RE.sub(lambda match: match.group(1) + "redacted-user@", value)
    return IP_CANDIDATE_RE.sub(_replace_ip, value)


def sanitize(value, key=None):
    normalized_key = key.lower() if isinstance(key, str) else None
    if normalized_key in SECRET_KEYS or (
        normalized_key and any(fragment in normalized_key for fragment in ("token", "password", "secret"))
    ):
        return "<redacted>"
    if normalized_key in USER_KEYS or (normalized_key and normalized_key.endswith("_username")):
        if isinstance(value, str):
            return "redacted-user"
    if normalized_key in SESSION_KEYS or (normalized_key and normalized_key.endswith("_session_id")):
        if isinstance(value, str):
            return "session-redacted"
    if normalized_key in TIME_KEYS or (normalized_key and normalized_key.endswith("_time")):
        if isinstance(value, str):
            return "1970-01-01T00:00:00Z"
    if normalized_key in HOST_KEYS or (
        normalized_key and (normalized_key.endswith("_host") or normalized_key.endswith("_ip"))
    ):
        if isinstance(value, str):
            try:
                address = ipaddress.ip_address(value.strip("[]"))
                return "192.0.2.1" if address.version == 4 else "2001:db8::1"
            except ValueError:
                return "host.example.invalid"
        if not isinstance(value, (dict, list)):
            return "<redacted-host>"
    if isinstance(value, dict):
        return {item_key: sanitize(item_value, item_key) for item_key, item_value in value.items()}
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    if isinstance(value, str):
        return sanitize_string(value)
    return value


def load_payload(text, input_format):
    if input_format == "json":
        return json.loads(text), False
    if input_format == "jsonl":
        return [json.loads(line) for line in text.splitlines() if line.strip()], True
    try:
        return json.loads(text), False
    except json.JSONDecodeError:
        return [json.loads(line) for line in text.splitlines() if line.strip()], True


def dump_payload(payload, jsonl):
    if jsonl:
        return "".join(
            json.dumps(sanitize(item), ensure_ascii=False, sort_keys=True) + "\n" for item in payload
        )
    return json.dumps(sanitize(payload), ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Sanitize TCP validation JSON/JSONL")
    parser.add_argument("input", nargs="?", default="-", help="input path, or - for stdin")
    parser.add_argument("-o", "--output", default="-", help="output path, or - for stdout")
    parser.add_argument("--format", choices=("auto", "json", "jsonl"), default="auto")
    args = parser.parse_args(argv)
    try:
        if args.input == "-":
            text = sys.stdin.read()
        else:
            with open(args.input, "r", encoding="utf-8") as handle:
                text = handle.read()
        payload, is_jsonl = load_payload(text, args.format)
        output = dump_payload(payload, is_jsonl)
        if args.output == "-":
            sys.stdout.write(output)
        else:
            with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(output)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.exit(2, "sanitize: {0}\n".format(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
