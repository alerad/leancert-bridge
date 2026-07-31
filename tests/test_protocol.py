"""Executable contract tests for the line-delimited JSON bridge."""

import json
import os
import subprocess
import unittest


def rat(n: int, d: int = 1) -> dict[str, int]:
    return {"n": n, "d": d}


def interval(lo: int, hi: int) -> dict[str, dict[str, int]]:
    return {"lo": rat(lo), "hi": rat(hi)}


class BridgeContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        binary = os.environ.get("LEAN_BRIDGE", ".lake/build/bin/lean_bridge")
        cls.process = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        cls.request_id = 0

    @classmethod
    def tearDownClass(cls) -> None:
        cls.process.terminate()
        cls.process.wait(timeout=10)
        for stream in (cls.process.stdin, cls.process.stdout, cls.process.stderr):
            if stream is not None:
                stream.close()

    def call(self, method: str, params: dict) -> dict:
        type(self).request_id += 1
        request_id = type(self).request_id
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(
            json.dumps({"id": request_id, "method": method, "params": params}) + "\n"
        )
        self.process.stdin.flush()
        response = json.loads(self.process.stdout.readline())
        self.assertEqual(response.get("id"), request_id)
        return response

    def test_info_advertises_typed_contract(self) -> None:
        result = self.call("get_info", {})["result"]
        self.assertEqual(result["bridge_api_version"], "1.1.0")
        self.assertEqual(result["certificate_schemas"], ["bound-check/1"])
        self.assertIn("check_bound", result["operations"])
        self.assertIn("var", result["expression_nodes"])

    def test_zero_denominator_is_rejected(self) -> None:
        response = self.call(
            "check_bound",
            {
                "expr": {"kind": "const", "val": rat(1, 0)},
                "box": [],
                "bound": rat(1),
                "isUpperBound": True,
            },
        )
        self.assertIn("denominator", response["error"])

    def test_inverted_interval_is_rejected(self) -> None:
        response = self.call(
            "check_bound",
            {
                "expr": {"kind": "var", "idx": 0},
                "box": [interval(2, 1)],
                "bound": rat(2),
                "isUpperBound": True,
            },
        )
        self.assertIn("lower endpoint", response["error"])

    def test_missing_variable_dimension_is_rejected(self) -> None:
        response = self.call(
            "check_bound",
            {
                "expr": {"kind": "var", "idx": 1},
                "box": [interval(0, 1)],
                "bound": rat(1),
                "isUpperBound": True,
            },
        )
        self.assertIn("outside box dimension", response["error"])

    def test_bound_outcomes_are_typed_and_backward_compatible(self) -> None:
        verified = self.call(
            "check_bound",
            {
                "expr": {"kind": "var", "idx": 0},
                "box": [interval(0, 1)],
                "bound": rat(1),
                "isUpperBound": True,
            },
        )["result"]
        self.assertTrue(verified["verified"])
        self.assertEqual(verified["status"], "verified")
        self.assertEqual(verified["certificate"]["schema_version"], "bound-check/1")
        self.assertIn("computed_hi", verified)

        inconclusive = self.call(
            "check_bound",
            {
                "expr": {"kind": "var", "idx": 0},
                "box": [interval(0, 1)],
                "bound": rat(0),
                "isUpperBound": True,
            },
        )["result"]
        self.assertFalse(inconclusive["verified"])
        self.assertEqual(inconclusive["status"], "inconclusive")
        self.assertIsNone(inconclusive["certificate"])


if __name__ == "__main__":
    unittest.main()
