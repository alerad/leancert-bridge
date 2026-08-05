#!/usr/bin/env python3
"""Stage the minimal runtime closure for the ordinary Bridge executable."""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    binary = arguments.binary.resolve()
    if not binary.is_file():
        parser.error(f"Bridge binary does not exist: {binary}")
    output = arguments.output.resolve()
    bin_dir = output / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable_name = "lean_bridge.exe" if sys.platform == "win32" else "lean_bridge"
    destination = bin_dir / executable_name
    shutil.copy2(binary, destination)
    destination.chmod(destination.stat().st_mode | 0o111)

    # Interpreter-enabled Windows builds use Lean's shared runtime. The normal
    # Bridge is currently static, but retaining colocated DLLs makes the staging
    # rule correct if its native link mode changes later.
    if sys.platform == "win32":
        for dll in sorted(binary.parent.glob("*.dll")):
            shutil.copy2(dll, bin_dir / dll.name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
