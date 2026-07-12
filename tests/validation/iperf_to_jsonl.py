#!/usr/bin/env python3
"""Convert iperf3 JSON results into validation JSONL records."""

import argparse
import datetime
import json
import os
import re
import sys


FILENAME_RE = re.compile(
    r"^(?P<variant>[^_]+)__(?P<run>[^_]+)__(?P<family>ipv4|ipv6)__"
    r"(?P<direction>upload|download)__p(?P<parallel>\d+)__d(?P<duration>\d+)"
    r"(?:__(?P<time>[^.]+))?\.json$",
    re.IGNORECASE,
)


def filename_metadata(path):
    """Parse metadata from variant__run__family__direction__pN__dN[__time].json."""
    match = FILENAME_RE.match(os.path.basename(path))
    if not match:
        return {}
    result = match.groupdict()
    result["family"] = result["family"].lower()
    result["direction"] = result["direction"].lower()
    result["parallel"] = int(result["parallel"])
    result["duration"] = int(result["duration"])
    return result


def _number(mapping, key):
    value = mapping.get(key) if isinstance(mapping, dict) else None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def _first_interval_bps(payload):
    intervals = payload.get("intervals")
    if not isinstance(intervals, list) or not intervals or not isinstance(intervals[0], dict):
        return None
    interval = intervals[0]
    direct = _number(interval.get("sum"), "bits_per_second")
    if direct is not None:
        return direct
    streams = interval.get("streams")
    if not isinstance(streams, list):
        return None
    values = [
        _number(stream, "bits_per_second")
        for stream in streams
        if isinstance(stream, dict)
    ]
    if not values or any(value is None for value in values):
        return None
    return sum(values)


def _payload_time(payload):
    timestamp = payload.get("start", {}).get("timestamp", {})
    if isinstance(timestamp, dict):
        if isinstance(timestamp.get("time"), str):
            return timestamp["time"]
        seconds = timestamp.get("timesecs")
        if isinstance(seconds, (int, float)) and not isinstance(seconds, bool):
            return datetime.datetime.fromtimestamp(
                seconds, tz=datetime.timezone.utc
            ).isoformat().replace("+00:00", "Z")
    return None


def convert(payload, metadata):
    end = payload.get("end") if isinstance(payload.get("end"), dict) else {}
    error = payload.get("error") if isinstance(payload.get("error"), str) else None
    bps = _number(end.get("sum_received"), "bits_per_second")
    retrans = _number(end.get("sum_sent"), "retransmits")
    first_bps = _first_interval_bps(payload)
    missing = [
        key
        for key in ("variant", "run", "family", "direction", "parallel", "duration")
        if metadata.get(key) is None
    ]
    if missing:
        raise ValueError("missing metadata: {0}".format(", ".join(missing)))
    success = error is None and bps is not None
    return {
        "variant": metadata["variant"],
        "run": metadata["run"],
        "family": metadata["family"],
        "direction": metadata["direction"],
        "parallel": int(metadata["parallel"]),
        "duration": int(metadata["duration"]),
        "success": success,
        # Receiver throughput is direction-independent in iperf3 JSON; for -R the
        # receiver is the client, while retransmits still belong to the sender.
        "bps": bps,
        "retrans": retrans,
        "first_bps": first_bps,
        "error": error if error is not None else (None if success else "missing sum_received"),
        "time": metadata.get("time") or _payload_time(payload),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description="Convert iperf3 JSON files to validation JSONL")
    parser.add_argument("files", nargs="+", help="iperf3 JSON files")
    for name in ("variant", "run", "family", "direction", "parallel", "duration", "time"):
        parser.add_argument("--" + name, help="override/inject metadata for every input")
    parser.add_argument("-o", "--output", default="-", help="JSONL output path, or - for stdout")
    args = parser.parse_args(argv)
    rows = []
    try:
        for path in args.files:
            metadata = filename_metadata(path)
            for name in ("variant", "run", "family", "direction", "parallel", "duration", "time"):
                value = getattr(args, name)
                if value is not None:
                    metadata[name] = value
            with open(path, "r", encoding="utf-8") as handle:
                payload = json.load(handle)
            if not isinstance(payload, dict):
                raise ValueError("{0}: expected JSON object".format(path))
            rows.append(convert(payload, metadata))
        output = "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows)
        if args.output == "-":
            sys.stdout.write(output)
        else:
            with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(output)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.exit(2, "iperf_to_jsonl: {0}\n".format(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
