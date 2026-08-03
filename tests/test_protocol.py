"""Executable contract tests for the line-delimited JSON bridge."""

import json
import os
import subprocess
import unittest
from pathlib import Path


FIXTURES = Path(__file__).parent / "fixtures" / "bridge-contract-2.1"


def bridge_executable(variable: str, default: str) -> str:
    """Return an explicit path suitable for CreateProcess on every runner."""
    return str(Path(os.environ.get(variable, default)).resolve())


def rat(n: int, d: int = 1) -> dict[str, int]:
    return {"n": n, "d": d}


def interval(lo: int, hi: int) -> dict[str, dict[str, int]]:
    return {"lo": rat(lo), "hi": rat(hi)}


class BridgeContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        binary = bridge_executable("LEAN_BRIDGE", ".lake/build/bin/lean_bridge")
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
        line = self.process.stdout.readline()
        if line == "":
            try:
                return_code = self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                return_code = self.process.poll()
            stderr = self.process.stderr.read() if self.process.stderr is not None else ""
            self.fail(
                f"lean_bridge exited before replying (exit code {return_code}):\n{stderr}"
            )
        response = json.loads(line)
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
        self.assertEqual(result["bridge_api_version"], "3.0.0")
        self.assertEqual(result["protocol_version"], "3.0.0")
        self.assertEqual(
            result["certificate_schemas"],
            [
                "bound-check/2",
                "strict-bound-check/1",
                "adaptive-bound-check/1",
                "krawczyk-check/1",
                "eventual-bound-check/1",
                "scalar-root-check/1",
                "integral-check/1",
                "registered-enclosure-check/1",
            ],
        )
        self.assertIn("check_bound", result["operations"])
        self.assertIn("var", result["expression_nodes"])
        self.assertEqual(result["capabilities"]["check_bound"]["schema_version"], "2.1")
        self.assertEqual(result["capabilities"]["check_bound"]["request_schema"], "check-bound-request/1")
        self.assertEqual(result["capabilities"]["check_bound"]["result_schema"], "bound-outcome/1")
        strict = result["capabilities"]["check_strict_bound"]
        self.assertEqual(strict["schema_version"], "2.7")
        self.assertEqual(strict["request_schema"], "check-strict-bound-request/1")
        self.assertEqual(strict["result_schema"], "strict-bound-outcome/1")
        self.assertEqual(strict["certificate_schemas"], ["strict-bound-check/1"])
        self.assertEqual(strict["relations"], ["lt", "gt"])
        adaptive = result["capabilities"]["verify_adaptive"]
        self.assertEqual(adaptive["schema_version"], "2.2")
        self.assertEqual(adaptive["result_schema"], "adaptive-bound-outcome/1")
        system_root = result["capabilities"]["check_unique_system_root"]
        self.assertEqual(system_root["schema_version"], "2.3")
        self.assertEqual(
            system_root["request_schema"], "check-unique-system-root-request/1"
        )
        self.assertEqual(
            system_root["result_schema"], "unique-system-root-outcome/1"
        )
        self.assertEqual(system_root["certificate_schemas"], ["krawczyk-check/1"])
        self.assertEqual(system_root["maximum_dimension"], 4)
        eventual = result["capabilities"]["check_eventual_bound"]
        self.assertEqual(eventual["schema_version"], "2.4")
        self.assertEqual(
            eventual["request_schema"], "check-eventual-bound-request/1"
        )
        self.assertEqual(eventual["result_schema"], "eventual-bound-outcome/1")
        self.assertEqual(
            eventual["certificate_schemas"], ["eventual-bound-check/1"]
        )
        scalar_root = result["capabilities"]["check_scalar_root"]
        self.assertEqual(scalar_root["schema_version"], "2.5")
        self.assertEqual(
            scalar_root["request_schema"], "check-scalar-root-request/1"
        )
        self.assertEqual(scalar_root["result_schema"], "scalar-root-outcome/1")
        self.assertEqual(scalar_root["claim_kinds"], ["exists", "unique", "excluded"])
        integral = result["capabilities"]["check_integral"]
        self.assertEqual(integral["schema_version"], "2.6")
        self.assertEqual(integral["request_schema"], "check-integral-request/1")
        self.assertEqual(integral["result_schema"], "integral-outcome/1")
        self.assertEqual(integral["certificate_schemas"], ["integral-check/1"])
        self.assertEqual(integral["relations"], ["eq", "lower", "upper"])
        registered = result["capabilities"]["check_registered_enclosure"]
        self.assertEqual(registered["schema_version"], "2.8")
        self.assertTrue(registered["profile_required"])
        self.assertFalse(registered["profile_loaded"])
        replay = result["capabilities"]["replay_registered_enclosure"]
        self.assertFalse(replay["candidate_execution"])
        self.assertIsNone(result["enclosure_profile"])
        self.assertNotIn("build", result)
        self.assertNotIn("dependencies", result)

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

    def test_strict_bounds_retain_checked_interior_margin(self) -> None:
        x = {"kind": "var", "idx": 0}
        verified = self.call(
            "check_strict_bound",
            {
                "expr": x,
                "box": [interval(0, 1)],
                "relation": "lt",
                "bound": rat(2),
            },
        )["result"]
        self.assertTrue(verified["verified"])
        self.assertEqual(verified["status"], "verified")
        self.assertEqual(verified["certified_bound"], rat(1))
        self.assertEqual(verified["target_bound"], rat(2))
        certificate = verified["certificate"]
        self.assertEqual(certificate["schema_version"], "strict-bound-check/1")
        self.assertEqual(
            certificate["checker"],
            "LeanCert.Validity.GlobalOpt.checkGlobalUpperBound",
        )
        self.assertEqual(
            certificate["verifier"],
            "LeanCert.Validity.GlobalOpt.verify_global_upper_bound",
        )
        self.assertEqual(
            certificate["payload"],
            {
                "schema_version": "checked-strict-bound/1",
                "expression": x,
                "box": [interval(0, 1)],
                "relation": "lt",
                "target_bound": rat(2),
                "certified_bound": rat(1),
                "config": {
                    "max_iterations": 1000,
                    "tolerance": rat(1, 1000),
                    "use_monotonicity": True,
                    "taylor_depth": 10,
                },
            },
        )

        lower = self.call(
            "check_strict_bound",
            {
                "expr": x,
                "box": [interval(0, 1)],
                "relation": "gt",
                "bound": rat(-1),
            },
        )["result"]
        self.assertTrue(lower["verified"])
        self.assertEqual(lower["certified_bound"], rat(0))
        self.assertEqual(
            lower["certificate"]["checker"],
            "LeanCert.Validity.GlobalOpt.checkGlobalLowerBound",
        )

    def test_strict_bound_rejects_boundary_touching_and_bad_relations(self) -> None:
        x = {"kind": "var", "idx": 0}
        touching = self.call(
            "check_strict_bound",
            {
                "expr": x,
                "box": [interval(0, 1)],
                "relation": "lt",
                "bound": rat(1),
            },
        )["result"]
        self.assertEqual(touching["status"], "inconclusive")
        self.assertIsNone(touching["certificate"])

        invalid = self.call(
            "check_strict_bound",
            {
                "expr": x,
                "box": [interval(0, 1)],
                "relation": "le",
                "bound": rat(2),
            },
        )
        self.assertIn("relation", self.error_message(invalid))

    def test_strict_bound_supports_multivariate_boxes(self) -> None:
        expression = {
            "kind": "add",
            "e1": {"kind": "var", "idx": 0},
            "e2": {"kind": "var", "idx": 1},
        }
        result = self.call(
            "check_strict_bound",
            {
                "expr": expression,
                "box": [interval(0, 1), interval(0, 1)],
                "relation": "lt",
                "bound": rat(3),
            },
        )["result"]
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["certified_bound"], rat(2))

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

    def test_unique_system_root_uses_checked_krawczyk_authority(self) -> None:
        x = {"kind": "var", "idx": 0}
        y = {"kind": "var", "idx": 1}
        const_minus_two = {"kind": "const", "val": rat(-2)}
        system = [
            {
                "kind": "add",
                "e1": {
                    "kind": "add",
                    "e1": {"kind": "mul", "e1": x, "e2": x},
                    "e2": y,
                },
                "e2": const_minus_two,
            },
            {
                "kind": "add",
                "e1": {
                    "kind": "add",
                    "e1": x,
                    "e2": {"kind": "mul", "e1": y, "e2": y},
                },
                "e2": const_minus_two,
            },
        ]
        box = [
            {"lo": rat(9, 10), "hi": rat(11, 10)},
            {"lo": rat(9, 10), "hi": rat(11, 10)},
        ]

        result = self.call(
            "check_unique_system_root", {"system": system, "box": box}
        )["result"]
        self.assertTrue(result["verified"])
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["backend"], "rational_krawczyk")
        self.assertEqual(result["search"]["source"], "automatic")
        self.assertGreaterEqual(result["search"]["attempts"], 1)
        self.assertIsNone(result["search"]["failure"])
        certificate = result["certificate"]
        self.assertEqual(certificate["schema_version"], "krawczyk-check/1")
        self.assertEqual(certificate["checker"], "LeanCert.Engine.krawczykCheck")
        self.assertEqual(
            certificate["verifier"], "LeanCert.Validity.verify_unique_system_root"
        )
        self.assertEqual(
            certificate["payload"]["schema_version"],
            "checked-unique-system-root/1",
        )
        self.assertEqual(certificate["payload"]["system"], system)
        self.assertEqual(certificate["payload"]["box"], box)

        manual = self.call(
            "check_unique_system_root",
            {
                "system": system,
                "box": box,
                "candidate": {
                    "center": [rat(1), rat(1)],
                    "preconditioner": [
                        [rat(2, 3), rat(-1, 3)],
                        [rat(-1, 3), rat(2, 3)],
                    ],
                },
            },
        )["result"]
        self.assertTrue(manual["verified"])
        self.assertEqual(manual["search"]["source"], "provided")

    def test_unique_system_root_rejects_bad_shapes_and_candidates(self) -> None:
        expression = {"kind": "var", "idx": 0}
        mismatch = self.call(
            "check_unique_system_root",
            {"system": [expression], "box": [interval(0, 1), interval(0, 1)]},
        )
        self.assertIn("does not match", self.error_message(mismatch))

        malformed_candidate = self.call(
            "check_unique_system_root",
            {
                "system": [expression],
                "box": [interval(-1, 1)],
                "candidate": {
                    "center": [rat(0)],
                    "preconditioner": [[rat(1), rat(0)]],
                },
            },
        )
        self.assertIn("preconditioner row", self.error_message(malformed_candidate))

        rejected = self.call(
            "check_unique_system_root",
            {
                "system": [
                    {
                        "kind": "add",
                        "e1": {"kind": "mul", "e1": expression, "e2": expression},
                        "e2": {"kind": "const", "val": rat(1)},
                    }
                ],
                "box": [interval(-1, 1)],
                "maxIterations": 2,
            },
        )["result"]
        self.assertFalse(rejected["verified"])
        self.assertEqual(rejected["status"], "candidate_rejected")
        self.assertIsNone(rejected["certificate"])
        self.assertIsNotNone(rejected["search"]["failure"])

    def test_eventual_bound_discovers_and_checks_exact_cutoff(self) -> None:
        result = self.call(
            "check_eventual_bound",
            {
                "coefficient": rat(3),
                "bound": rat(1, 1000),
                "exponent": 2,
            },
        )["result"]
        self.assertTrue(result["verified"])
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["backend"], "rational_reciprocal_power")
        self.assertEqual(result["cutoff"], 55)
        self.assertEqual(result["search"]["source"], "automatic")
        self.assertTrue(result["search"]["refinement_complete"])
        certificate = result["certificate"]
        self.assertEqual(certificate["schema_version"], "eventual-bound-check/1")
        self.assertEqual(
            certificate["checker"],
            "LeanCert.Validity.checkReciprocalPowerUpper",
        )
        self.assertEqual(
            certificate["verifier"],
            "LeanCert.Validity.verify_reciprocal_power_upper",
        )
        self.assertEqual(
            certificate["payload"],
            {
                "schema_version": "checked-eventual-bound/1",
                "coefficient": rat(3),
                "bound": rat(1, 1000),
                "exponent": 2,
                "cutoff": 55,
            },
        )

    def test_scalar_root_claims_emit_fixed_checked_certificates(self) -> None:
        x = {"kind": "var", "idx": 0}
        for claim, expression, checker, verifier in (
            (
                "exists",
                x,
                "LeanCert.Validity.RootFinding.checkSignChange",
                "LeanCert.Validity.RootFinding.verify_sign_change",
            ),
            (
                "unique",
                x,
                "LeanCert.Validity.RootFinding.checkNewtonContractsCore",
                "LeanCert.Validity.RootFinding.verify_unique_root_computable",
            ),
            (
                "excluded",
                {
                    "kind": "add",
                    "e1": x,
                    "e2": {"kind": "const", "val": rat(2)},
                },
                "LeanCert.Validity.RootFinding.checkNoRoot",
                "LeanCert.Validity.RootFinding.verify_no_root",
            ),
        ):
            with self.subTest(claim=claim):
                result = self.call(
                    "check_scalar_root",
                    {"expr": expression, "interval": interval(-1, 1), "claim": claim},
                )["result"]
                self.assertTrue(result["verified"])
                self.assertEqual(result["status"], "verified")
                self.assertEqual(result["claim"], claim)
                certificate = result["certificate"]
                self.assertEqual(certificate["schema_version"], "scalar-root-check/1")
                self.assertEqual(certificate["checker"], checker)
                self.assertEqual(certificate["verifier"], verifier)
                self.assertEqual(
                    certificate["payload"],
                    {
                        "schema_version": "checked-scalar-root/1",
                        "expression": expression,
                        "interval": interval(-1, 1),
                        "claim": claim,
                        "config": {"taylor_depth": 10},
                    },
                )

    def test_scalar_root_rejections_are_typed_and_certificate_free(self) -> None:
        rejected = self.call(
            "check_scalar_root",
            {
                "expr": {"kind": "var", "idx": 0},
                "interval": interval(1, 2),
                "claim": "exists",
            },
        )["result"]
        self.assertEqual(rejected["status"], "candidate_rejected")
        self.assertIsNone(rejected["certificate"])

        unsupported = self.call(
            "check_scalar_root",
            {
                "expr": {"kind": "sqrt", "e": {"kind": "var", "idx": 0}},
                "interval": interval(1, 2),
                "claim": "unique",
            },
        )["result"]
        self.assertEqual(unsupported["status"], "unsupported")
        self.assertIsNone(unsupported["certificate"])

    def test_exact_integral_equality_retains_fixed_polynomial_check(self) -> None:
        x = {"kind": "var", "idx": 0}
        expression = {"kind": "mul", "e1": x, "e2": x}
        result = self.call(
            "check_integral",
            {
                "expr": expression,
                "interval": interval(0, 1),
                "relation": "eq",
                "bound": rat(1, 3),
            },
        )["result"]
        self.assertTrue(result["verified"])
        self.assertEqual(result["route"], "exact_polynomial")
        self.assertEqual(result["enclosure"], {"lo": rat(1, 3), "hi": rat(1, 3)})
        certificate = result["certificate"]
        self.assertEqual(certificate["schema_version"], "integral-check/1")
        self.assertEqual(certificate["checker"], "LeanCert.Engine.QPoly.checkExactIntegral")
        self.assertEqual(
            certificate["verifier"], "LeanCert.Engine.QPoly.integral_eq_of_check"
        )
        self.assertEqual(
            certificate["payload"],
            {
                "schema_version": "checked-integral/1",
                "expression": expression,
                "interval": interval(0, 1),
                "relation": "eq",
                "bound": rat(1, 3),
                "partitions": None,
            },
        )

    def test_integral_bound_retains_discovered_partition_candidate(self) -> None:
        expression = {"kind": "exp", "e": {"kind": "var", "idx": 0}}
        result = self.call(
            "check_integral",
            {
                "expr": expression,
                "interval": interval(0, 1),
                "relation": "upper",
                "bound": rat(2),
                "startPartitions": 8,
                "maxPartitions": 128,
            },
        )["result"]
        self.assertTrue(result["verified"])
        self.assertEqual(result["route"], "checked_partitions")
        self.assertEqual(result["search"]["source"], "automatic")
        self.assertEqual(result["search"]["chosen_partitions"], 8)
        certificate = result["certificate"]
        self.assertEqual(
            certificate["checker"],
            "LeanCert.Validity.Integration.checkIntegralPartitionUpperBound",
        )
        self.assertEqual(certificate["payload"]["partitions"], 8)
        self.assertEqual(certificate["payload"]["relation"], "upper")

    def test_integral_failures_are_typed_and_certificate_free(self) -> None:
        x = {"kind": "var", "idx": 0}
        incorrect = self.call(
            "check_integral",
            {
                "expr": {"kind": "mul", "e1": x, "e2": x},
                "interval": interval(0, 1),
                "relation": "eq",
                "bound": rat(1, 2),
            },
        )["result"]
        self.assertEqual(incorrect["status"], "candidate_rejected")
        self.assertIsNone(incorrect["certificate"])

        unsupported = self.call(
            "check_integral",
            {
                "expr": {"kind": "log", "e": x},
                "interval": interval(1, 2),
                "relation": "upper",
                "bound": rat(1),
            },
        )["result"]
        self.assertEqual(unsupported["status"], "unsupported")
        self.assertIsNone(unsupported["certificate"])

        invalid_interval = self.call(
            "check_integral",
            {
                "expr": x,
                "interval": interval(1, 0),
                "relation": "eq",
                "bound": rat(0),
            },
        )
        self.assertEqual(invalid_interval["error"]["code"], "invalid_params")

    def test_eventual_bound_checks_supplied_cutoff_without_discovery(self) -> None:
        accepted = self.call(
            "check_eventual_bound",
            {
                "coefficient": rat(3),
                "bound": rat(1, 1000),
                "exponent": 2,
                "cutoff": 100,
            },
        )["result"]
        self.assertTrue(accepted["verified"])
        self.assertEqual(accepted["cutoff"], 100)
        self.assertEqual(accepted["search"], {"source": "provided"})

        rejected = self.call(
            "check_eventual_bound",
            {
                "coefficient": rat(3),
                "bound": rat(1, 1000),
                "exponent": 2,
                "cutoff": 10,
            },
        )["result"]
        self.assertFalse(rejected["verified"])
        self.assertEqual(rejected["status"], "candidate_rejected")
        self.assertEqual(rejected["failure"]["kind"], "rejected_cutoff")
        self.assertIsNone(rejected["certificate"])

    def test_eventual_bound_failures_are_typed(self) -> None:
        unsupported = self.call(
            "check_eventual_bound",
            {
                "coefficient": rat(-1),
                "bound": rat(1),
                "exponent": 2,
            },
        )["result"]
        self.assertEqual(unsupported["status"], "unsupported")
        self.assertEqual(unsupported["failure"]["kind"], "negative_coefficient")

        impossible = self.call(
            "check_eventual_bound",
            {
                "coefficient": rat(1),
                "bound": rat(0),
                "exponent": 2,
            },
        )["result"]
        self.assertEqual(impossible["status"], "candidate_rejected")
        self.assertEqual(impossible["failure"]["kind"], "impossible_bound")

        exhausted = self.call(
            "check_eventual_bound",
            {
                "coefficient": rat(3),
                "bound": rat(1, 1000),
                "exponent": 2,
                "maxChecks": 1,
            },
        )["result"]
        self.assertEqual(exhausted["status"], "inconclusive")
        self.assertEqual(exhausted["failure"]["kind"], "search_exhausted")
        self.assertIsNone(exhausted["certificate"])

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

    def test_standard_binary_rejects_unlinked_profile_module(self) -> None:
        binary = bridge_executable("LEAN_BRIDGE", ".lake/build/bin/lean_bridge")
        profile = Path(__file__).parent / "fixtures" / "enclosure-profile.json"
        completed = subprocess.run(
            [binary, "--enclosure-profile", str(profile)],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("not statically linked", completed.stdout + completed.stderr)


class RegisteredEnclosureProfileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        binary = bridge_executable(
            "LEAN_BRIDGE_PROFILED", ".lake/build/bin/lean_bridge_profile_test"
        )
        profile = Path(__file__).parent / "fixtures" / "enclosure-profile.json"
        cls.process = subprocess.Popen(
            [binary, "--enclosure-profile", str(profile)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        cls.request_id = 10000

    @classmethod
    def tearDownClass(cls) -> None:
        cls.process.terminate()
        cls.process.wait(timeout=10)
        for stream in (cls.process.stdin, cls.process.stdout, cls.process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except BrokenPipeError:
                    pass

    def call(self, method: str, params: dict) -> dict:
        type(self).request_id += 1
        request_id = type(self).request_id
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(
            json.dumps({"id": request_id, "method": method, "params": params}) + "\n"
        )
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if line == "":
            try:
                return_code = self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                return_code = self.process.poll()
            stderr = self.process.stderr.read() if self.process.stderr is not None else ""
            self.fail(
                f"profiled lean_bridge exited before replying (exit code {return_code}):\n{stderr}"
            )
        response = json.loads(line)
        self.assertEqual(response.get("id"), request_id)
        return response

    @staticmethod
    def claim() -> dict:
        return {
            "expression": {
                "kind": "registered",
                "function": "LeanCert.Bridge.TestEnclosureExtension.shifted",
                "argument": {"kind": "var", "idx": 0},
            },
            "domain": interval(0, 1),
            "relation": "le",
            "bound": rat(2),
        }

    def test_profile_is_frozen_and_advertised(self) -> None:
        info = self.call("get_info", {})["result"]
        profile = info["enclosure_profile"]
        self.assertEqual(profile["name"], "bridge-generic-test")
        self.assertEqual(
            profile["allowed_functions"],
            ["LeanCert.Bridge.TestEnclosureExtension.shifted"],
        )
        self.assertTrue(
            info["capabilities"]["check_registered_enclosure"]["profile_loaded"]
        )

    def test_discovery_and_fixed_replay(self) -> None:
        claim = self.claim()
        discovered = self.call("check_registered_enclosure", claim)["result"]
        self.assertEqual(discovered["status"], "verified")
        self.assertEqual(discovered["enclosure"], interval(1, 2))
        certificate = discovered["certificate"]
        self.assertEqual(certificate["schema"], "registered-enclosure-check/1")

        replayed = self.call(
            "replay_registered_enclosure",
            {"claim": claim, "certificate": certificate},
        )["result"]
        self.assertEqual(replayed["status"], "verified")
        self.assertTrue(replayed["replayed"])

        corrupted = json.loads(json.dumps(certificate))
        corrupted["tree"]["entries"][0]["output"] = interval(99, 99)
        rejected = self.call(
            "replay_registered_enclosure",
            {"claim": claim, "certificate": corrupted},
        )["result"]
        self.assertIn(
            rejected["status"], {"candidate_rejected", "verification_failure"}
        )

    def test_unlisted_declaration_is_not_resolved(self) -> None:
        claim = self.claim()
        claim["expression"]["function"] = "LeanCert.Bridge.TestEnclosureExtension.notAllowed"
        response = self.call("check_registered_enclosure", claim)
        self.assertEqual(response["error"]["code"], "enclosure_execution_error")


if __name__ == "__main__":
    unittest.main()
