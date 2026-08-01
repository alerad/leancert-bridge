# Bridge Contract 2.1

LeanCert Bridge uses one line-delimited JSON request and response per operation.
It is not JSON-RPC 2.0. Every valid request has an `id`, `method`, and `params`;
every response to a valid request repeats the same `id` and contains exactly
one of `result` or `error`.

## Compatibility

`bridge_api_version` follows semantic versioning. Additive response fields and
new operations increment the minor version. Removing fields or changing their
meaning requires a major version. Contract 2.0 introduces structured errors,
immutable build provenance, and explicit per-operation schema identities.
Contract 2.1 adds replayable checked-bound payloads and resolved dependency
identities. It is an additive minor release of Contract 2.

## Handshake

`get_info` reports:

- protocol name, version, and NDJSON framing;
- bridge, Lean, and LeanCert versions;
- source revision, source digest, environment digest, and build profile;
- the exact Lean toolchain and LeanCert source, input revision, and resolved commit;
- supported operations and expression nodes;
- certificate schemas and verification routes;
- per-operation request, result, outcome, backend, certificate, and route capabilities.

Clients must negotiate capabilities before other calls. An operation appearing
in `operations` is callable; it is a typed checked operation only when it also
appears in `capabilities` with a checked result schema.

## Errors

Infrastructure and protocol failures use:

```json
{"error":{"code":"invalid_params","message":"..."}}
```

Stable codes are `parse_error`, `invalid_request`, `invalid_params`, and
`unknown_method`. Errors are not mathematical outcomes.

## Mathematical outcomes

Checked mathematical non-success is a tagged result:

- `verified`: the advertised checker accepted the retained certificate;
- `inconclusive`: the checked enclosure was insufficient;
- `unsupported`: no advertised checked route supports the request;
- `domain_obstruction`: a partial operation could not be certified on the domain.

Only `check_bound` currently advertises a typed checked capability. Other
operations remain available as computational/discovery endpoints, but clients
must not infer theorem authority from their untagged result dictionaries.

`check_bound` retains `verified`, `computed_lo`, and `computed_hi` for migration
and additionally returns `status`, `direction`, `enclosure`, `backend`, and a
certificate descriptor. The two enclosure representations must agree. A
verified result must retain a certificate; every other status must not.

### Replayable bound certificates

Contract 2.1 advertises `bound-check/2`. Its certificate contains a
`global-opt-bound-replay/1` payload constructed from the values actually
checked after request decoding. The payload retains:

- the lowered LeanCert core expression;
- the normalized exact rational box and requested bound;
- the checked direction;
- every global-optimization configuration value.

Derived request nodes such as subtraction, division, and powers are lowered in
the replay payload exactly as they were before checking. Clients may compute a
canonical digest of this payload for identity, but must not synthesize or alter
the payload and still describe it as bridge-issued evidence.

## Input validity

The bridge rejects zero rational denominators, inverted intervals, and
expressions referencing coordinates outside the supplied box. It never repairs
malformed mathematical input by substituting zero or `[0, 0]`.

## Verification route

`compiled_checker` means the released native bridge evaluated the named
LeanCert Boolean checker and reports its Golden Theorem. It does not claim that
a fresh proof term was elaborated and kernel-reduced for each request.

## Build provenance

Local builds report the explicit `development`/`unavailable` sentinel values.
CI runs `scripts/write_build_info.py` before compilation, embedding the Git
revision, a digest of bridge source, a digest of the Lean toolchain and resolved
Lake environment, and the build profile. Released binaries must never contain
development sentinel provenance.
