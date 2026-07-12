#!/usr/bin/env python3
"""Compare successful before/after validation records paired by run."""

import argparse
import json
import sys
from collections import defaultdict

import analyze


PAIR_GROUP_FIELDS = ("family", "direction", "parallel", "duration")


def compare(records, before_variant="head", after_variant="candidate"):
    indexed = {}
    group_runs = defaultdict(set)
    for record in records:
        analyze.validate_record(record)
        if "run" not in record or not isinstance(record["run"], (str, int)):
            raise ValueError("record: run must be a string or integer")
        if record["variant"] not in (before_variant, after_variant):
            continue
        group = tuple(record[field] for field in PAIR_GROUP_FIELDS)
        key = (group, str(record["run"]), record["variant"])
        if key in indexed:
            raise ValueError("duplicate record for group/run/variant: {0}".format(key))
        indexed[key] = record
        group_runs[group].add(str(record["run"]))

    groups = []
    for group in sorted(group_runs, key=lambda value: tuple(str(item) for item in value)):
        deltas = {metric: [] for metric in analyze.METRIC_FIELDS}
        paired_runs = []
        unmatched_runs = []
        for run in sorted(group_runs[group]):
            before = indexed.get((group, run, before_variant))
            after = indexed.get((group, run, after_variant))
            if before is None or after is None or not before["success"] or not after["success"]:
                unmatched_runs.append(run)
                continue
            paired_runs.append(run)
            for metric in analyze.METRIC_FIELDS:
                before_value = before[metric]
                after_value = after[metric]
                if before_value is not None and after_value is not None:
                    deltas[metric].append(float(after_value) - float(before_value))

        result = {field: value for field, value in zip(PAIR_GROUP_FIELDS, group)}
        result.update(
            {
                "before_variant": before_variant,
                "after_variant": after_variant,
                "paired_runs": paired_runs,
                "pair_count": len(paired_runs),
                "unmatched_runs": unmatched_runs,
                "delta": {
                    metric: {
                        "summary": analyze.metric_summary(values),
                        "bootstrap_mean_ci_95": analyze.bootstrap_mean_ci(values),
                    }
                    for metric, values in deltas.items()
                },
            }
        )
        groups.append(result)
    return {"schema_version": 1, "groups": groups}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Compare JSONL validation records paired by run")
    parser.add_argument("input", nargs="?", default="-", help="JSONL path, or - for stdin")
    parser.add_argument("-o", "--output", default="-", help="JSON output path, or - for stdout")
    parser.add_argument("--before", default="head", help="before variant (default: head)")
    parser.add_argument("--after", default="candidate", help="after variant (default: candidate)")
    args = parser.parse_args(argv)
    try:
        if args.input == "-":
            records = analyze.load_jsonl(sys.stdin)
        else:
            with open(args.input, "r", encoding="utf-8") as handle:
                records = analyze.load_jsonl(handle)
        output = json.dumps(
            compare(records, args.before, args.after), ensure_ascii=False, indent=2, sort_keys=True
        ) + "\n"
        if args.output == "-":
            sys.stdout.write(output)
        else:
            with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(output)
    except (OSError, ValueError) as exc:
        parser.exit(2, "compare: {0}\n".format(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
