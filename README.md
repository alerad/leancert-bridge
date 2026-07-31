# LeanCert Bridge

Standalone Lean bridge binary for the Python SDK.

## Purpose

This repo builds and releases `lean_bridge` binaries that implement LeanCert's
line-delimited JSON protocol.

Runtime direction stays one-way:

- Python SDK starts `lean_bridge`
- Python sends requests over stdin/stdout
- Bridge returns checked outcomes where advertised and exact build provenance

Only operations listed under the handshake's `capabilities` object are typed
checked APIs. Other advertised operations are computational or discovery
endpoints. See [BRIDGE_CONTRACT.md](BRIDGE_CONTRACT.md).

## Local Build

```bash
lake update
lake build lean_bridge
LEAN_BRIDGE=.lake/build/bin/lean_bridge python3 tests/test_protocol.py
```

Binary output:

- Unix: `.lake/build/bin/lean_bridge`
- Windows: `.lake/build/bin/lean_bridge.exe`

### Windows Note

If local builds fail with `failed to create ... .c` under `.lake/packages`,
use a shorter checkout path (for example `C:\\ws\\leancert-bridge`) or enable
Windows long paths.

## Releases

Tag format: `bridge-vX.Y.Z`

On tag push, CI builds platform binaries and publishes GitHub release assets:

- `lean_bridge-linux-x86_64`
- `lean_bridge-macos-x86_64`
- `lean_bridge-macos-arm64`
- `lean_bridge-windows-x86_64.exe`
