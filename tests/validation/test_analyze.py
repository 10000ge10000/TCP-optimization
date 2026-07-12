import io
import json
import math
import os
import subprocess
import sys
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analyze  # noqa: E402


def record(**overrides):
    value = {
        "variant": "candidate",
        "family": "ipv6",
        "direction": "upload",
        "parallel": 1,
        "duration": 20,
        "success": True,
        "bps": 100.0,
        "retrans": 4,
        "first_bps": 80.0,
        "error": None,
        "time": "2026-01-01T00:00:00Z",
    }
    value.update(overrides)
    return value


class AnalyzeTests(unittest.TestCase):
    def test_metric_summary_and_outlier_retention(self):
        summary = analyze.metric_summary([1, 1, 1, 1, 100])
        self.assertEqual(summary["count"], 5)
        self.assertEqual(summary["median"], 1)
        self.assertEqual(summary["min"], 1)
        self.assertEqual(summary["max"], 100)
        self.assertEqual(summary["tukey_outliers"], [100.0])
        self.assertAlmostEqual(summary["mean"], 20.8)

    def test_sample_stddev_and_cv_edges(self):
        one = analyze.metric_summary([5])
        self.assertIsNone(one["sample_stddev"])
        self.assertIsNone(one["cv"])
        zero_mean = analyze.metric_summary([-1, 1])
        self.assertIsNotNone(zero_mean["sample_stddev"])
        self.assertIsNone(zero_mean["cv"])
        empty = analyze.metric_summary([])
        self.assertIsNone(empty["mean"])

    def test_bootstrap_ci_is_deterministic_and_requires_two_samples(self):
        self.assertIsNone(analyze.bootstrap_mean_ci([1]))
        first = analyze.bootstrap_mean_ci([1, 2, 3, 4])
        second = analyze.bootstrap_mean_ci([1, 2, 3, 4])
        self.assertEqual(first, second)
        self.assertEqual(first["samples"], 10000)
        self.assertEqual(first["seed"], analyze.BOOTSTRAP_SEED)
        self.assertLessEqual(first["low"], 2.5)
        self.assertGreaterEqual(first["high"], 2.5)
        with self.assertRaisesRegex(ValueError, "at least 10000"):
            analyze.bootstrap_mean_ci([1, 2], samples=9999)

    def test_groups_successes_and_failures(self):
        result = analyze.analyze(
            [
                record(bps=100),
                record(success=False, bps=None, retrans=None, first_bps=None, error="timeout"),
                record(variant="head", family="ipv4", bps=90),
            ]
        )
        self.assertEqual(len(result["groups"]), 2)
        candidate = next(group for group in result["groups"] if group["variant"] == "candidate")
        self.assertEqual(candidate["attempts"], 2)
        self.assertEqual(candidate["successes"], 1)
        self.assertEqual(candidate["success_rate"], 0.5)
        self.assertEqual(candidate["failure_reasons"], ["timeout"])
        self.assertEqual(candidate["metrics"]["bps"]["count"], 1)

    def test_load_jsonl_validates_required_fields(self):
        data = json.dumps(record()) + "\n\n"
        self.assertEqual(len(analyze.load_jsonl(io.StringIO(data))), 1)
        with self.assertRaisesRegex(ValueError, "missing fields"):
            analyze.load_jsonl(io.StringIO('{"variant":"head"}\n'))

    def test_cli_reads_jsonl_and_emits_json(self):
        process = subprocess.run(
            [sys.executable, os.path.join(HERE, "analyze.py")],
            input=json.dumps(record()) + "\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout)["groups"][0]["attempts"], 1)


if __name__ == "__main__":
    unittest.main()
