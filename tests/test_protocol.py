"""Executable contract tests for the line-delimited JSON bridge."""

import json
import os
import subprocess
import unittest
from pathlib import Path


FIXTURES = Path(__file__).parent / "fixtures" / "bridge-contract-2.0"


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

    def error_message(self, response: dict) -> str:
        error = response["error"]
        self.assertIsInstance(error, dict)
        self.assertIn(error["code"], {"parse_error", "invalid_request", "invalid_params", "unknown_method"})
        self.assertIsInstance(error["message"], str)
        return error["message"]

    def test_info_advertises_typed_contract(self) -> None:
        result = self.call("get_info", {})["result"]
        self.assertEqual(result["protocol_name"], "leancert-line-json")
        self.assertEqual(result["framing"], "ndjson")
        self.assertEqual(result["bridge_api_version"], "2.0.0")
        self.assertEqual(result["protocol_version"], "2.0.0")
        self.assertEqual(result["certificate_schemas"], ["bound-check/1"])
        self.assertIn("check_bound", result["operations"])
        self.assertIn("var", result["expression_nodes"])
        self.assertEqual(result["capabilities"]["check_bound"]["request_schema"], "check-bound-request/1")
        self.assertEqual(result["capabilities"]["check_bound"]["result_schema"], "bound-outcome/1")
        self.assertNotIn("verify_adaptive", result["capabilities"])
        self.assertEqual(
            set(result["build"]),
            {"source_revision", "source_digest", "environment_digest", "profile"},
        )

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
        self.assertIn("denominator", self.error_message(response))

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
        self.assertIn("lower endpoint", self.error_message(response))

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
        self.assertIn("outside box dimension", self.error_message(response))

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
        expected = json.loads((FIXTURES / "verified-bound.json").read_text())
        self.assertEqual(verified, expected)

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

    def test_unknown_method_uses_structured_error(self) -> None:
        response = self.call("not_an_operation", {})
        self.assertEqual(response["error"]["code"], "unknown_method")
        self.assertIn("not_an_operation", response["error"]["message"])


if __name__ == "__main__":
    unittest.main()
