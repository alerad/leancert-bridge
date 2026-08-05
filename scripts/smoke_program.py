#!/usr/bin/env python3
"""Open a portable program copy and exercise the Bridge without Lake or sources."""

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
    with tempfile.TemporaryDirectory(prefix="leancert-program-smoke-") as home:
        runtime = Runtime(home=home)
        program = runtime.open_program_copy(arguments.archive)
        with program.spawn_interactive(
            policy=ExecutionPolicy(timeout_seconds=30, max_output_bytes=1_000_000)
        ) as session:
            session.stdin.write('{"id":1,"method":"get_info","params":{}}\n')
            session.stdin.flush()
            response = json.loads(session.stdout.readline())
        if response.get("id") != 1 or not isinstance(response.get("result"), dict):
            raise RuntimeError(f"invalid Bridge response: {response!r}")
        print(json.dumps({"program_id": program.id, "bridge_info": response["result"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
