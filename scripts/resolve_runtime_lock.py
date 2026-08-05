#!/usr/bin/env python3
"""Resolve the exact managed Bridge environment published to the OCI cache."""

from __future__ import annotations

import argparse
import re
from dataclasses import replace
from pathlib import Path

from lean_runtime import Runtime


BRIDGE_REFERENCE = "github:alerad/leancert-bridge@{revision}"
ARTIFACT_COMMAND = (
    "lake",
    "exe",
    "@LeanCertBridge/lean_bridge_runtime_prepare",
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--revision", required=True, help="exact 40-character Bridge commit")
    result.add_argument("--output", type=Path, default=Path("environment.lock.json"))
    result.add_argument("--timeout", type=float, default=3600)
    return result


def main() -> int:
    args = parser().parse_args()
    if re.fullmatch(r"[0-9a-fA-F]{40}", args.revision) is None:
        raise SystemExit("--revision must be an exact 40-character Git commit")
    runtime = Runtime(prebuilt="never")
    reference = BRIDGE_REFERENCE.format(revision=args.revision)
    spec = runtime.spec_from_references([reference])
    if len(spec.packages) != 1:
        raise RuntimeError("the Bridge reference must resolve to exactly one direct package")
    package = replace(spec.packages[0], artifact_command=ARTIFACT_COMMAND)
    lock = runtime.resolve(replace(spec, packages=(package,)), timeout=args.timeout)
    lock.write(args.output)
    print(lock.lock_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
