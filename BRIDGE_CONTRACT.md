# Bridge Contract (v1)

This file defines the compatibility contract between:

- `leancert-python` client (`LeanClient`)
- `leancert-bridge` binary (`lean_bridge`)

## Compatibility Rule

- `bridge_api_version` uses semver semantics.
- Major version changes are breaking.
- Python SDK must reject incompatible major versions at startup.

## Required Methods

- `get_info`
- `ping`
- `eval_interval`
- `eval_interval_dyadic`
- `eval_interval_affine`
- `global_min`
- `global_max`
- `global_min_dyadic`
- `global_max_dyadic`
- `global_min_affine`
- `global_max_affine`
- `check_bound`
- `integrate`
- `find_roots`
- `find_unique_root`
- `verify_adaptive`
- `forward_interval`
- `deriv_interval`

## Error Shape

Every response is line-delimited JSON. On failure, response must include `error` with a human-readable message.

## Version Handshake

Bridge must provide method:

- `get_info` -> `{ bridge_api_version, lean_version, bridge_version }`

Python should call `get_info` on startup and enforce supported version range.
