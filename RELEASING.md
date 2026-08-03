# Releasing leancert-bridge

## 1. Ensure bridge code and contract are updated

- Update `LeanBridge.lean`
- If the protocol shape changed, update `BRIDGE_CONTRACT.md`
- If breaking, bump `bridgeApiVersion` major
- Confirm the tagged CI build reports the tag commit, non-sentinel source and
  environment digests, and `profile: release`
- Copy the contract fixtures into the matching `leancert-python` protocol tests

## 2. Create release tag

Push an independent Bridge SemVer tag such as:

- `v0.8.0`

Do not encode the Lean or LeanCert Core version in the Bridge tag. Confirm the
exact pinned toolchain and resolved Core revision in the release handshake.

CI builds binaries for Linux, macOS (x86_64/arm64), and Windows, then publishes release assets.

## Asset names

- `lean_bridge-linux-x86_64`
- `lean_bridge-macos-x86_64`
- `lean_bridge-macos-arm64`
- `lean_bridge-windows-x86_64.exe`

## 3. Bump python pin

In `leancert-python`, update `bridge-version.txt` to this tag.
