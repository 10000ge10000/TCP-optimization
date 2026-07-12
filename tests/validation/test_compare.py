import os
import sys
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import compare  # noqa: E402


def record(variant, run, bps, retrans, first_bps, success=True):
    return {
        "variant": variant,
        "run": run,
        "family": "ipv6",
        "direction": "upload",
        "parallel": 1,
        "duration": 20,
        "success": success,
        "bps": bps,
        "retrans": retrans,
        "first_bps": first_bps,
        "error": None if success else "timeout",
        "time": "1970-01-01T00:00:00Z",
    }


class CompareTests(unittest.TestCase):
    def test_pairs_by_run_and_computes_after_minus_before(self):
        records = [
            record("head", "01", 100, 10, 50),
            record("candidate", "01", 110, 8, 60),
            record("head", "02", 90, 12, 45),
            record("candidate", "02", 95, 9, 50),
            record("head", "03", 80, 20, 40),
        ]
        group = compare.compare(records)["groups"][0]
        self.assertEqual(group["paired_runs"], ["01", "02"])
        self.assertEqual(group["unmatched_runs"], ["03"])
        self.assertEqual(group["delta"]["bps"]["summary"]["mean"], 7.5)
        self.assertEqual(group["delta"]["retrans"]["summary"]["mean"], -2.5)
        self.assertIsNotNone(group["delta"]["bps"]["bootstrap_mean_ci_95"])

    def test_failed_pair_is_unmatched_and_small_ci_is_null(self):
        records = [
            record("head", 1, 100, 10, 50),
            record("candidate", 1, 101, 9, 51),
            record("head", 2, 100, 10, 50),
            record("candidate", 2, None, None, None, success=False),
        ]
        group = compare.compare(records)["groups"][0]
        self.assertEqual(group["pair_count"], 1)
        self.assertEqual(group["unmatched_runs"], ["2"])
        self.assertIsNone(group["delta"]["bps"]["bootstrap_mean_ci_95"])

    def test_duplicate_pair_key_is_rejected(self):
        item = record("head", "01", 100, 10, 50)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            compare.compare([item, dict(item)])


if __name__ == "__main__":
    unittest.main()
