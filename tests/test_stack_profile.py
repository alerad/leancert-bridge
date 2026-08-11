from __future__ import annotations

import json
import unittest
from pathlib import Path

from scripts.generate_stack_profile import (
    canonical_capability_digest,
    core_revision,
    stack_profile,
)

ROOT = Path(__file__).resolve().parents[1]


class StackProfileTests(unittest.TestCase):
    def handshake(self) -> dict:
        return json.loads(
            (ROOT / "tests/fixtures/bridge-contract-2.1/handshake.json").read_text()
        )

    def test_capability_digest_is_stable_and_semantic(self) -> None:
        info = self.handshake()
        digest = canonical_capability_digest(info)
        self.assertEqual(
            digest,
            "sha256:04531fa6a10549979d5e673980bdc734f924b20b6c04cbc139fe3e9b870d783c",
        )
        reordered = dict(reversed(list(info.items())))
        self.assertEqual(canonical_capability_digest(reordered), digest)
        info["capabilities"]["check_bound"]["backends"].append("new_backend")
        self.assertNotEqual(canonical_capability_digest(info), digest)

    def test_profile_is_derived_from_resolved_build_and_handshake(self) -> None:
        profile = stack_profile(
            self.handshake(),
            bridge_revision="a" * 40,
            core_revision_value="b" * 40,
            toolchain="leanprover/lean4:v4.32.2",
        )
        self.assertEqual(profile["leancert.bridge.revision"], "a" * 40)
        self.assertEqual(profile["leancert.core.revision"], "b" * 40)
        self.assertEqual(profile["leancert.protocol.version"], "2.1.0")
        self.assertTrue(profile["leancert.capability.digest"].startswith("sha256:"))

    def test_profile_rejects_toolchain_drift(self) -> None:
        with self.assertRaisesRegex(ValueError, "disagree"):
            stack_profile(
                self.handshake(),
                bridge_revision="a" * 40,
                core_revision_value="b" * 40,
                toolchain="leanprover/lean4:v4.33.0",
            )

    def test_core_revision_comes_from_exact_lake_resolution(self) -> None:
        self.assertEqual(
            core_revision(ROOT / "lake-manifest.json"),
            "06cf13980fde15b21fe2600cbb8b8d4e0e612f3c",
        )


if __name__ == "__main__":
    unittest.main()
