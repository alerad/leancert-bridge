# LeanCert Bridge

Standalone Lean bridge binary for the Python SDK.

## Purpose

This repo builds and releases `lean_bridge` binaries that implement the JSON-RPC bridge on top of `leancert`.

Runtime direction stays one-way:

- Python SDK starts `lean_bridge`
- Python sends JSON-RPC over stdin/stdout
- Bridge returns verified results

## Local Build

```bash
lake update
lake build lean_bridge
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
