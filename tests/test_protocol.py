"""Executable contract tests for the line-delimited JSON bridge."""

import json
import os
import subprocess
import unittest
from pathlib import Path


FIXTURES = Path(__file__).parent / "fixtures" / "bridge-contract-2.1"


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
        self.assertEqual(result["bridge_api_version"], "2.2.0")
        self.assertEqual(result["protocol_version"], "2.2.0")
        self.assertEqual(
            result["certificate_schemas"],
            ["bound-check/2", "adaptive-bound-check/1"],
        )
        self.assertIn("check_bound", result["operations"])
        self.assertIn("var", result["expression_nodes"])
        self.assertEqual(result["capabilities"]["check_bound"]["schema_version"], "2.1")
        self.assertEqual(result["capabilities"]["check_bound"]["request_schema"], "check-bound-request/1")
        self.assertEqual(result["capabilities"]["check_bound"]["result_schema"], "bound-outcome/1")
        adaptive = result["capabilities"]["verify_adaptive"]
        self.assertEqual(adaptive["schema_version"], "2.2")
        self.assertEqual(adaptive["result_schema"], "adaptive-bound-outcome/1")
        self.assertEqual(
            set(result["build"]),
            {"source_revision", "source_digest", "environment_digest", "profile"},
        )
        self.assertEqual(result["dependencies"]["lean"]["toolchain"], "leanprover/lean4:v4.32.2")
        self.assertEqual(result["dependencies"]["leancert"]["input_revision"], "v4.32.2.3")
        self.assertEqual(
            result["dependencies"]["leancert"]["resolved_revision"],
            "6f0c9ae5bcd5e40463d9771f06b33ef145c242f6",
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
        self.assertEqual(verified["certificate"]["schema_version"], "bound-check/2")
        payload = verified["certificate"]["payload"]
        self.assertEqual(payload["schema_version"], "global-opt-bound-replay/1")
        self.assertEqual(payload["direction"], "upper")
        self.assertEqual(payload["config"]["max_iterations"], 1000)
        self.assertEqual(payload["config"]["tolerance"], rat(1, 1000))
        self.assertIn("computed_hi", verified)
        expected = json.loads((FIXTURES / "verified-bound.json").read_text())
        self.assertEqual(verified, expected)

    def test_adaptive_bound_uses_checked_optimizer_authority(self) -> None:
        result = self.call(
            "verify_adaptive",
            {
                "expr": {
                    "kind": "mul",
                    "e1": {"kind": "var", "idx": 0},
                    "e2": {
                        "kind": "sub",
                        "e1": {"kind": "const", "val": rat(1)},
                        "e2": {"kind": "var", "idx": 0},
                    },
                },
                "box": [interval(0, 1)],
                "bound": rat(3, 10),
                "isUpperBound": True,
                "maxIters": 1000,
                "tolerance": rat(1, 1000),
                "taylorDepth": 10,
            },
        )["result"]
        self.assertTrue(result["verified"])
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["backend"], "rational_checked_global_optimization")
        certificate = result["certificate"]
        self.assertEqual(certificate["schema_version"], "adaptive-bound-check/1")
        self.assertEqual(
            certificate["checker"],
            "LeanCert.Engine.Optimization.globalMaximizeRationalChecked",
        )
        self.assertEqual(
            certificate["verifier"],
            "LeanCert.Engine.Optimization.globalMaximizeRationalChecked_hi_correct",
        )
        self.assertEqual(
            certificate["payload"]["schema_version"],
            "checked-global-opt-bound/1",
        )

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

    def test_replay_payload_uses_the_lowered_checked_expression(self) -> None:
        verified = self.call(
            "check_bound",
            {
                "expr": {
                    "kind": "sub",
                    "e1": {"kind": "var", "idx": 0},
                    "e2": {"kind": "const", "val": rat(0)},
                },
                "box": [interval(0, 1)],
                "bound": rat(1),
                "isUpperBound": True,
            },
        )["result"]
        payload = verified["certificate"]["payload"]
        self.assertEqual(
            payload["expression"],
            {
                "kind": "add",
                "e1": {"kind": "var", "idx": 0},
                "e2": {
                    "kind": "neg",
                    "e": {"kind": "const", "val": rat(0)},
                },
            },
        )

    def test_lean_432_evaluator_migrations_preserve_existing_operations(self) -> None:
        expression = {"kind": "var", "idx": 0}
        box = [interval(0, 1)]
        rational = self.call("eval_interval", {"expr": expression, "box": box})["result"]
        self.assertEqual((rational["lo"], rational["hi"]), (rat(0), rat(1)))

        dyadic = self.call(
            "eval_interval_dyadic",
            {
                "expr": expression,
                "box": box,
                "config": {"precision": -53, "taylorDepth": 10, "roundAfterOps": 0},
            },
        )["result"]
        self.assertEqual((dyadic["lo"], dyadic["hi"]), (rat(0), rat(1)))

        affine = self.call(
            "eval_interval_affine", {"expr": expression, "box": box}
        )["result"]
        self.assertEqual((affine["lo"], affine["hi"]), (rat(0), rat(1)))

        minimum = self.call(
            "global_min", {"expr": expression, "box": box, "maxIters": 2}
        )["result"]
        maximum = self.call(
            "global_max", {"expr": expression, "box": box, "maxIters": 2}
        )["result"]
        self.assertLessEqual(
            minimum["lo"]["n"] * minimum["hi"]["d"],
            minimum["hi"]["n"] * minimum["lo"]["d"],
        )
        self.assertLessEqual(
            maximum["lo"]["n"] * maximum["hi"]["d"],
            maximum["hi"]["n"] * maximum["lo"]["d"],
        )

    def test_unknown_method_uses_structured_error(self) -> None:
        response = self.call("not_an_operation", {})
        self.assertEqual(response["error"]["code"], "unknown_method")
        self.assertIn("not_an_operation", response["error"]["message"])


if __name__ == "__main__":
    unittest.main()
