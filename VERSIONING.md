# Versioning

LeanCert has three independent version axes. They answer different questions
and must not be inferred from one another.

## Product releases

Each distributed repository uses its own release version. In this repository,
tags such as `v1.0.0` identify releases of the Bridge source and artifacts.
They do not encode a Lean toolchain or Mathlib release.

The older `bridge-v4.31.x` and `v4.32.2.x` tags predate independent Bridge
SemVer. They remain valid historical identifiers but must not be used as the
format for new releases.

## Bridge Contract

`bridge_api_version`, documented in [BRIDGE_CONTRACT.md](BRIDGE_CONTRACT.md),
identifies the protocol and semantic contract negotiated between the Bridge
and its clients. Contract `3.0` is not a package version and does not require
the Python SDK, Lean Runtime, or Bridge release itself to have major version 3.

Bridge `v1.0.0` is the first stable Bridge release that speaks Contract `3.0`.
That relationship is release metadata, not a rule that the two major versions
must remain numerically equal.

## Lean ecosystem identity

The exact Lean toolchain, LeanCert Core revision, Mathlib revision, and
transitive dependency graph belong in the resolved Lake manifest and Lean
Runtime provenance. They are reproducibility inputs, not Bridge release
numbers.

Consequently:

- use Bridge SemVer tags to communicate Bridge releases;
- negotiate `bridge_api_version` for protocol compatibility;
- use exact commits, locks, and environment identities for reproducibility.
