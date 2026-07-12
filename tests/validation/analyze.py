#!/usr/bin/env python3
"""Aggregate TCP validation JSONL records without discarding outliers."""

import argparse
import json
import math
import statistics
import sys
from collections import defaultdict


REQUIRED_FIELDS = (
    "variant",
    "family",
    "direction",
    "parallel",
    "duration",
    "success",
    "bps",
    "retrans",
    "first_bps",
    "error",
    "time",
)
GROUP_FIELDS = ("variant", "family", "direction", "parallel", "duration")
METRIC_FIELDS = ("bps", "retrans", "first_bps")
BOOTSTRAP_SAMPLES = 10000
BOOTSTRAP_SEED = 20260712


def _percentile(sorted_values, fraction):
    """Return an inclusive, linearly interpolated percentile."""
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = (len(sorted_values) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return sorted_values[lower]
    weight = position - lower
    return sorted_values[lower] * (1 - weight) + sorted_values[upper] * weight


def metric_summary(values):
    """Summarize numeric values and retain Tukey outliers in the result."""
    numeric = [float(value) for value in values if value is not None]
    if not numeric:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "min": None,
            "max": None,
            "sample_stddev": None,
            "cv": None,
            "tukey_outliers": [],
        }
    ordered = sorted(numeric)
    mean = statistics.mean(numeric)
    q1 = _percentile(ordered, 0.25)
    q3 = _percentile(ordered, 0.75)
    iqr = q3 - q1
    lower = q1 - 1.5 * iqr
    upper = q3 + 1.5 * iqr
    stddev = statistics.stdev(numeric) if len(numeric) >= 2 else None
    return {
        "count": len(numeric),
        "mean": mean,
        "median": statistics.median(numeric),
        "min": min(numeric),
        "max": max(numeric),
        "sample_stddev": stddev,
        "cv": (stddev / mean) if stddev is not None and mean != 0 else None,
        "tukey_outliers": [value for value in numeric if value < lower or value > upper],
    }


def bootstrap_mean_ci(values, samples=BOOTSTRAP_SAMPLES, seed=BOOTSTRAP_SEED):
    """Return a deterministic percentile bootstrap CI for the arithmetic mean."""
    import random

    numeric = [float(value) for value in values if value is not None]
    if len(numeric) < 2:
        return None
    if samples < 10000:
        raise ValueError("bootstrap samples must be at least 10000")
    rng = random.Random(seed)
    count = len(numeric)
    means = sorted(
        sum(numeric[rng.randrange(count)] for _ in range(count)) / count for _ in range(samples)
    )
    return {
        "low": _percentile(means, 0.025),
        "high": _percentile(means, 0.975),
        "confidence": 0.95,
        "samples": samples,
        "seed": seed,
    }


def validate_record(record, line_number=None):
    location = "record" if line_number is None else "line {0}".format(line_number)
    if not isinstance(record, dict):
        raise ValueError("{0}: expected JSON object".format(location))
    missing = [field for field in REQUIRED_FIELDS if field not in record]
    if missing:
        raise ValueError("{0}: missing fields: {1}".format(location, ", ".join(missing)))
    if not isinstance(record["success"], bool):
        raise ValueError("{0}: success must be boolean".format(location))
    for field in ("parallel", "duration"):
        if isinstance(record[field], bool) or not isinstance(record[field], (int, float)):
            raise ValueError("{0}: {1} must be numeric".format(location, field))
    for field in METRIC_FIELDS:
        value = record[field]
        if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float))):
            raise ValueError("{0}: {1} must be numeric or null".format(location, field))
    return record


def load_jsonl(stream):
    records = []
    for line_number, raw_line in enumerate(stream, 1):
        if not raw_line.strip():
            continue
        try:
            record = json.loads(raw_line)
        except json.JSONDecodeError as exc:
            raise ValueError("line {0}: invalid JSON: {1}".format(line_number, exc.msg)) from exc
        records.append(validate_record(record, line_number))
    return records


def analyze(records):
    grouped = defaultdict(list)
    for record in records:
        validate_record(record)
        grouped[tuple(record[field] for field in GROUP_FIELDS)].append(record)

    results = []
    for group_key in sorted(grouped, key=lambda key: tuple(str(item) for item in key)):
        samples = grouped[group_key]
        successes = [sample for sample in samples if sample["success"]]
        result = {field: value for field, value in zip(GROUP_FIELDS, group_key)}
        result.update(
            {
                "attempts": len(samples),
                "successes": len(successes),
                "success_rate": len(successes) / len(samples),
                "failure_reasons": [
                    sample["error"] or "unspecified" for sample in samples if not sample["success"]
                ],
                # Only successful measurements are aggregated. Failed samples remain
                # represented by attempts, success_rate and failure_reasons.
                "metrics": {
                    field: metric_summary(sample[field] for sample in successes)
                    for field in METRIC_FIELDS
                },
            }
        )
        results.append(result)
    return {"schema_version": 1, "groups": results}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Aggregate TCP validation JSONL records")
    parser.add_argument("input", nargs="?", default="-", help="JSONL path, or - for stdin")
    parser.add_argument("-o", "--output", default="-", help="JSON output path, or - for stdout")
    args = parser.parse_args(argv)
    try:
        if args.input == "-":
            records = load_jsonl(sys.stdin)
        else:
            with open(args.input, "r", encoding="utf-8") as handle:
                records = load_jsonl(handle)
        result = json.dumps(analyze(records), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        if args.output == "-":
            sys.stdout.write(result)
        else:
            with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(result)
    except (OSError, ValueError) as exc:
        parser.exit(2, "analyze: {0}\n".format(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
