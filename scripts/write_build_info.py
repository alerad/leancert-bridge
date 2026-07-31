"""Generate compile-time bridge provenance for CI release binaries."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def digest(paths: tuple[Path, ...]) -> str:
    value = hashlib.sha256()
    for path in paths:
        value.update(path.name.encode())
        value.update(b"\0")
        value.update(path.read_bytes())
        value.update(b"\0")
    return "sha256:" + value.hexdigest()


def lean_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--profile", default="ci")
    arguments = parser.parse_args()

    source_digest = digest((ROOT / "LeanBridge.lean",))
    environment_digest = digest(
        (ROOT / "lean-toolchain", ROOT / "lakefile.toml", ROOT / "lake-manifest.json")
    )
    output = ROOT / "BridgeBuild" / "BuildInfo.lean"
    output.write_text(
        "namespace LeanCert.Bridge.BuildInfo\n\n"
        f'def sourceRevision : String := "{lean_string(arguments.source_revision)}"\n'
        f'def sourceDigest : String := "{source_digest}"\n'
        f'def environmentDigest : String := "{environment_digest}"\n'
        f'def profile : String := "{lean_string(arguments.profile)}"\n\n'
        "end LeanCert.Bridge.BuildInfo\n"
    )


if __name__ == "__main__":
    main()
