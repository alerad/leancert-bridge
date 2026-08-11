#!/usr/bin/env python3
"""Derive content-addressed LeanCert stack provenance from a built Bridge."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any


def canonical_capability_digest(info: dict[str, Any]) -> str:
    """Match the SDK's semantic capability identity using raw handshake JSON."""
    capabilities = info.get("capabilities")
    if not isinstance(capabilities, dict):
        raise TypeError("Bridge handshake does not contain a capabilities object")
    normalized = []
    for operation in sorted(capabilities):
        value = capabilities[operation]
        if not isinstance(value, dict):
            raise TypeError(f"Bridge capability {operation!r} is not an object")
        normalized.append(
            {
                "operation": operation,
                "schema_version": value.get("schema_version"),
                "request_schema": value.get("request_schema"),
                "result_schema": value.get("result_schema"),
                "outcomes": sorted(value.get("outcomes", [])),
                "backends": sorted(value.get("backends", [])),
                "certificate_schemas": sorted(value.get("certificate_schemas", [])),
                "verification_routes": sorted(value.get("verification_routes", [])),
            }
        )
    payload = {
        "protocol_version": info.get("protocol_version"),
        "enclosure_profile": info.get("enclosure_profile"),
        "operations": sorted(info.get("operations", [])),
        "expression_nodes": sorted(info.get("expression_nodes", [])),
        "certificate_schemas": sorted(info.get("certificate_schemas", [])),
        "verification_routes": sorted(info.get("verification_routes", [])),
        "capabilities": normalized,
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def bridge_info(binary: Path) -> dict[str, Any]:
    request = json.dumps({"id": 1, "method": "get_info", "params": {}}) + "\n"
    completed = subprocess.run(
        [str(binary.resolve())],
        input=request,
        text=True,
        capture_output=True,
        check=True,
        timeout=30,
    )
    line = completed.stdout.splitlines()
    if not line:
        raise RuntimeError("Bridge exited without returning its handshake")
    response = json.loads(line[0])
    result = response.get("result") if isinstance(response, dict) else None
    if (
        not isinstance(response, dict)
        or response.get("id") != 1
        or not isinstance(result, dict)
    ):
        raise RuntimeError(f"Bridge returned an invalid handshake: {response!r}")
    return result


def core_revision(manifest: Path) -> str:
    value = json.loads(manifest.read_text(encoding="utf-8"))
    packages = value.get("packages") if isinstance(value, dict) else None
    if not isinstance(packages, list):
        raise TypeError("Lake manifest does not contain a package list")
    matches = [
        item
        for item in packages
        if isinstance(item, dict) and item.get("name") == "leancert"
    ]
    if len(matches) != 1:
        raise ValueError("Lake manifest must resolve exactly one leancert package")
    revision = matches[0].get("rev")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40,64}", revision):
        raise ValueError("Lake manifest does not contain an exact LeanCert revision")
    return revision


def stack_profile(
    info: dict[str, Any],
    *,
    bridge_revision: str,
    core_revision_value: str,
    toolchain: str,
) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{40,64}", bridge_revision):
        raise ValueError("Bridge revision must be an exact Git commit")
    lean_version = info.get("lean_version")
    if not isinstance(lean_version, str) or not toolchain.endswith(f":v{lean_version}"):
        raise ValueError("Bridge handshake and lean-toolchain disagree")
    required = {
        "bridge_version": info.get("bridge_version"),
        "leancert_version": info.get("leancert_version"),
        "protocol_version": info.get("protocol_version"),
    }
    if not all(isinstance(value, str) and value for value in required.values()):
        raise ValueError("Bridge handshake omits required version metadata")
    reported_core = required["leancert_version"]
    if (
        re.fullmatch(r"[0-9a-f]{40,64}", reported_core)
        and reported_core != core_revision_value
    ):
        raise ValueError("Bridge handshake and resolved LeanCert revision disagree")
    return {
        "lean.toolchain": toolchain,
        "leancert.bridge.revision": bridge_revision,
        "leancert.bridge.version": required["bridge_version"],
        "leancert.capability.digest": canonical_capability_digest(info),
        "leancert.core.revision": core_revision_value,
        "leancert.core.version": required["leancert_version"],
        "leancert.protocol.version": required["protocol_version"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--bridge-revision", required=True)
    parser.add_argument(
        "--lake-manifest", type=Path, default=Path("lake-manifest.json")
    )
    parser.add_argument("--lean-toolchain", type=Path, default=Path("lean-toolchain"))
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    toolchain = arguments.lean_toolchain.read_text(encoding="utf-8").strip()
    profile = stack_profile(
        bridge_info(arguments.binary),
        bridge_revision=arguments.bridge_revision,
        core_revision_value=core_revision(arguments.lake_manifest),
        toolchain=toolchain,
    )
    arguments.output.write_text(
        json.dumps(profile, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(profile, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
