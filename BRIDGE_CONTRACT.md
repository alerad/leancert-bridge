# Bridge Contract 1.1

LeanCert Bridge uses one line-delimited JSON request and response per operation.
It is not JSON-RPC 2.0. Every parseable request has an `id`, `method`, and
`params`; every response repeats the same `id` and contains exactly one of
`result` or `error`.

## Compatibility

`bridge_api_version` follows semantic versioning. Additive response fields and
new operations increment the minor version. Removing fields or changing their
meaning requires a major version.

## Handshake

`get_info` reports protocol, bridge, Lean, and LeanCert versions; supported
operations and expression nodes; certificate schemas; backends; outcomes; and
verification routes. Clients must negotiate capabilities before other calls.

## Mathematical outcomes

Normal mathematical non-success is a tagged result:

- `verified`: the advertised checker accepted the certificate;
- `inconclusive`: the checked enclosure was insufficient;
- `unsupported`: no advertised checked route supports the expression/configuration;
- `domain_obstruction`: a partial operation could not be certified on the domain.

Malformed requests, protocol violations, and internal failures use `error`.

`check_bound` retains the legacy `verified`, `computed_lo`, and `computed_hi`
fields through protocol 1.x and additionally returns `status`, `direction`,
`enclosure`, `backend`, and a `certificate` descriptor.

## Input validity

The bridge rejects zero rational denominators, inverted intervals, and
expressions that reference coordinates outside the supplied box. It never
repairs malformed mathematical input by substituting zero or `[0, 0]`.

## Verification route

`compiled_checker` means the released native bridge evaluated a LeanCert
Boolean checker whose Golden Theorem is named in the result. It does not claim
that a fresh proof term was elaborated and kernel-checked for each request.
