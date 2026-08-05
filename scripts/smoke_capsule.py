#!/usr/bin/env python3
"""Import a capsule archive and exercise the Bridge without Lake or sources."""

from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path

from lean_runtime import ExecutionPolicy, Runtime


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="leancert-capsule-smoke-") as home:
        runtime = Runtime(home=home)
        capsule = runtime.import_capsule(arguments.archive)
        with capsule.spawn_interactive(
            policy=ExecutionPolicy(timeout_seconds=30, max_output_bytes=1_000_000)
        ) as session:
            session.stdin.write('{"id":1,"method":"get_info","params":{}}\n')
            session.stdin.flush()
            response = json.loads(session.stdout.readline())
        if response.get("id") != 1 or not isinstance(response.get("result"), dict):
            raise RuntimeError(f"invalid Bridge response: {response!r}")
        print(json.dumps({"capsule_id": capsule.id, "bridge_info": response["result"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
