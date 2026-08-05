# LeanCert Bridge

Standalone Lean bridge binary for the Python SDK.

## Purpose

This repo builds and releases `lean_bridge` binaries that implement LeanCert's
line-delimited JSON protocol.

Runtime direction stays one-way:

- Python SDK starts `lean_bridge`
- Python sends requests over stdin/stdout
- Bridge returns checked outcomes where advertised; the process manager records exact build provenance

Only operations listed under the handshake's `capabilities` object are typed
checked APIs. Other advertised operations are computational or discovery
endpoints. See [BRIDGE_CONTRACT.md](BRIDGE_CONTRACT.md).

Checked capabilities currently cover fixed bounds, adaptive bounds, unique
nonlinear-system roots certified by exact rational Krawczyk certificates, and
reciprocal-power eventual bounds with supplied or automatically discovered
cutoffs. They also cover fixed scalar-root claims and exact or partition-bounded
definite integrals with replayable checker inputs. Strict global bounds retain
a checked interior rational bound plus the exact margin to their target.
Contract 2.8 can also load downstream unary enclosure rules through an
immutable, allowlisted profile and return complete replayable checker trees.

## Local Build

```bash
lake update
lake build lean_bridge
LEAN_BRIDGE=.lake/build/bin/lean_bridge python3 tests/test_protocol.py
```

## Downstream enclosure profiles

Registered downstream functions are opt-in at process startup. A profile is a
small JSON document:

```json
{
  "schema_version": "leancert-enclosure-profile/1",
  "name": "my-verified-functions",
  "modules": ["MyProject.Enclosures"],
  "allowed_functions": ["MyProject.specialFunction"],
  "leancert_revision": "<exact bridge Core revision>",
  "environment_digest": "sha256:<downstream lockfile/source digest>"
}
```

Build a tiny downstream entry point that statically imports the registered
module and declares that module to the Bridge runtime:

```lean
import LeanBridge
import MyProject.Enclosures

unsafe def main (args : List String) : IO Unit :=
  LeanCert.Bridge.run args #[`MyProject.Enclosures]
```

The corresponding `lean_exe` must set `supportInterpreter := true`. The Bridge
build policy keeps native initializer entry points visible on Windows while
avoiding PE's export-table limit. Launch the resulting profiled executable with
the immutable manifest:

```bash
lake env .lake/build/bin/my_profiled_bridge --enclosure-profile profile.json
```

The environment and registry are frozen before the NDJSON loop begins. The
profile must match the Bridge's exact LeanCert revision, and requests can only
use structured expressions referencing allowlisted functions. Discovery emits
a `registered-enclosure-check/1` certificate; fixed replay reruns registered
checkers and reconstructs the kernel proof without executing candidates.

Binary output:

- Unix: `.lake/build/bin/lean_bridge`
- Windows: `.lake/build/bin/lean_bridge.exe`

### Windows Note

If local builds fail with `failed to create ... .c` under `.lake/packages`,
use a shorter checkout path (for example `C:\\ws\\leancert-bridge`) or enable
Windows long paths.

Profiled Bridge executables use Lean's interpreter-enabled shared runtime. On
Windows, keep the Lean runtime DLLs from the active toolchain's `bin` directory
beside the profiled executable. The ordinary released Bridge does not enable
the interpreter and remains a standalone executable.

## Releases

Bridge releases use independent semantic versions such as `v0.8.0`. The exact
Lean toolchain and LeanCert Core revision are pinned by the build and reported
by the runtime handshake; they are compatibility metadata, not components of
the Bridge version. Older toolchain-aligned tags remain valid historical
releases.

Ordinary SDK execution is also published as a small, multi-computer
ready-to-run program in the `ghcr.io/alerad/leancert-bridge-programs` program
library. It contains only the Bridge executable and its runtime libraries plus
an exact program description. It does not contain Mathlib sources or claim
independent rebuildability. Full Lean environments remain the authority for
kernel replay, downstream profile builds, and reproducibility audits.

On tag push, CI builds platform binaries and publishes GitHub release assets:

- `lean_bridge-linux-x86_64`
- `lean_bridge-macos-x86_64`
- `lean_bridge-macos-arm64`
- `lean_bridge-windows-x86_64.exe`

The same matrix publishes the exact managed Bridge environment to the
`ghcr.io/alerad/leancert-runtime` environment library. Each computer uploads
its immutable environment copy and computer record; a final job completes the
publication only after all computers prepare the same exact environment.
`leancert-python` can then download and verify this environment through Lean
Runtime 2 instead of rebuilding LeanCert and Mathlib locally. When no suitable
download is available, Lean Runtime can still fall back to a source build.

Manual workflow dispatch can publish a specific 40-character Bridge revision.
This is useful when preparing the environment library before updating the
SDK's exact Bridge pin. The exact environment description includes
`lean_bridge_runtime_prepare`, which hydrates Mathlib artifacts and builds
`lean_bridge` before the environment is published.
