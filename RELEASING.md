# Releasing leancert-bridge

## 1. Ensure bridge code and contract are updated

- Update `LeanBridge.lean`
- If the protocol shape changed, update `BRIDGE_CONTRACT.md`
- If breaking, bump `bridgeApiVersion` major
- Confirm the tagged CI build reports the tag commit, non-sentinel source and
  environment digests, and `profile: release`
- Copy the contract fixtures into the matching `leancert-python` protocol tests

## 2. Create release tag

Push tag like:

- `bridge-v0.2.0`

CI builds binaries for Linux, macOS (x86_64/arm64), and Windows, then publishes release assets.

## Asset names

- `lean_bridge-linux-x86_64`
- `lean_bridge-macos-x86_64`
- `lean_bridge-macos-arm64`
- `lean_bridge-windows-x86_64.exe`

## 3. Bump python pin

In `leancert-python`, update `bridge-version.txt` to this tag.
