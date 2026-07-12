import json
import os
import sys
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import iperf_to_jsonl  # noqa: E402


def metadata():
    return {
        "variant": "candidate",
        "run": "01",
        "family": "ipv6",
        "direction": "download",
        "parallel": 1,
        "duration": 20,
    }


class IperfToJsonlTests(unittest.TestCase):
    def test_explicit_end_and_first_interval_semantics(self):
        payload = {
            "start": {"timestamp": {"timesecs": 1}},
            "intervals": [{"sum": {"bits_per_second": 75.0}}],
            "end": {
                "sum_sent": {"bits_per_second": 101.0, "retransmits": 7},
                "sum_received": {"bits_per_second": 99.0},
            },
        }
        result = iperf_to_jsonl.convert(payload, metadata())
        self.assertTrue(result["success"])
        self.assertEqual(result["bps"], 99.0)
        self.assertEqual(result["retrans"], 7)
        self.assertEqual(result["first_bps"], 75.0)
        self.assertEqual(result["time"], "1970-01-01T00:00:01Z")

    def test_first_interval_falls_back_to_stream_sum(self):
        payload = {
            "intervals": [
                {"streams": [{"bits_per_second": 20.0}, {"bits_per_second": 30.0}]}
            ],
            "end": {"sum_sent": {}, "sum_received": {"bits_per_second": 45.0}},
        }
        result = iperf_to_jsonl.convert(payload, metadata())
        self.assertEqual(result["first_bps"], 50.0)
        self.assertIsNone(result["retrans"])

    def test_missing_and_error_fields_are_not_fabricated_as_zero(self):
        missing = iperf_to_jsonl.convert({"end": {}}, metadata())
        self.assertFalse(missing["success"])
        self.assertIsNone(missing["bps"])
        self.assertIsNone(missing["retrans"])
        self.assertIsNone(missing["first_bps"])
        self.assertEqual(missing["error"], "missing sum_received")

        failed = iperf_to_jsonl.convert({"error": "control socket timeout"}, metadata())
        self.assertFalse(failed["success"])
        self.assertEqual(failed["error"], "control socket timeout")

    def test_filename_metadata_convention(self):
        result = iperf_to_jsonl.filename_metadata(
            "head__run-05__ipv4__upload__p4__d20__20260712T010203Z.json"
        )
        self.assertEqual(
            result,
            {
                "variant": "head",
                "run": "run-05",
                "family": "ipv4",
                "direction": "upload",
                "parallel": 4,
                "duration": 20,
                "time": "20260712T010203Z",
            },
        )
        self.assertEqual(iperf_to_jsonl.filename_metadata("unmatched.json"), {})

    def test_missing_metadata_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing metadata"):
            iperf_to_jsonl.convert({}, {})


if __name__ == "__main__":
    unittest.main()
