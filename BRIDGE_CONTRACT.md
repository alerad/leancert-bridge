# Bridge Contract 3.0

LeanCert Bridge uses one line-delimited JSON request and response per operation.
It is not JSON-RPC 2.0. Every valid request has an `id`, `method`, and `params`;
every response to a valid request repeats the same `id` and contains exactly
one of `result` or `error`.

## Compatibility

`bridge_api_version` follows semantic versioning. Additive response fields and
new operations increment the minor version. Removing fields or changing their
meaning requires a major version. Contract 2.0 introduces structured errors
and explicit per-operation schema identities. Contract 2.1 adds replayable
checked-bound payloads. Contract 2.2 adds checked adaptive-bound outcomes. Contract 2.3
adds checked unique nonlinear-system roots through rational Krawczyk
certificates. Contract 2.4 adds checked reciprocal-power eventual bounds with
supplied or automatically discovered cutoffs. These are additive minor
releases of Contract 2. Contract 2.5 adds fixed scalar-root existence,
uniqueness, and exclusion claims. Contract 2.6 adds exact polynomial integral
equalities and checked one-sided integral bounds. Contract 2.7 adds strict
global bounds by composing a checked interior rational bound with an exact
strict margin.
Contract 2.8 adds immutable downstream enclosure profiles, structured
registered-function expressions, and fixed checker replay.
Contract 3.0 removes Bridge-authored build and dependency provenance from the
handshake. Managed execution environments own those supply-chain identities;
the Bridge continues to report only protocol and mathematical capabilities.

## Handshake

`get_info` reports:

- protocol name, version, and NDJSON framing;
- bridge, Lean, and LeanCert versions;
- supported operations and expression nodes;
- certificate schemas and verification routes;
- per-operation request, result, outcome, backend, certificate, and route capabilities.

Repository revisions, dependency locks, environment identity, and execution
identity are supplied by the process manager (`lean-runtime` for the Python
SDK), not asserted by this mathematical protocol. A loaded downstream
enclosure profile still reports its own profile and environment digests because
those values identify mathematical inputs to registered-rule selection.

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
- `candidate_rejected`: a well-formed untrusted candidate failed its checker.

`check_bound`, `check_strict_bound`, `verify_adaptive`, `check_unique_system_root`,
`check_eventual_bound`, `check_scalar_root`, and `check_integral` advertise
typed checked capabilities. Other operations remain available as computational
or discovery endpoints, but clients must not infer theorem authority from their
untagged result dictionaries.

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

### Replayable strict-bound certificates

Contract 2.7 advertises `check_strict_bound` with request schema
`check-strict-bound-request/1`, result schema `strict-bound-outcome/1`, and
certificate schema `strict-bound-check/1`. The operation accepts `lt` for
`expression < target` and `gt` for `target < expression`.

The global optimizer proposes an exact rational `certified_bound` strictly
inside the requested target. The bridge reruns `checkGlobalUpperBound` or
`checkGlobalLowerBound` at that fixed interior value. A verified conclusion is
authorized only by both facts:

- the existing Golden Theorem proves the corresponding non-strict global bound;
- exact rational comparison proves the retained interior bound has a strict
  margin to the requested target.

The certificate retains the lowered expression, exact rational box, relation,
target, certified interior bound, and complete optimizer configuration. A box
touching the target is `inconclusive`, never silently weakened to a non-strict
claim. The original `check_bound` schemas and semantics remain unchanged.

### Checked unique system roots

Contract 2.3 advertises `check_unique_system_root` with request schema
`check-unique-system-root-request/1`, result schema
`unique-system-root-outcome/1`, and certificate schema `krawczyk-check/1`.

The request contains a square system of supported expressions, an exact
rational box, fixed search limits, and optionally an exact rational center and
preconditioner supplied by an external numerical solver. Automatic search and
supplied candidates are both untrusted. The bridge reconstructs the selected
`KrawczykCert`, evaluates `LeanCert.Engine.krawczykCheck`, and emits `verified`
only when that checker returns true. The retained verifier identity is
`LeanCert.Validity.verify_unique_system_root`.

Expected search failures are typed as `candidate_rejected` or `unsupported`;
malformed dimensions and matrices are protocol errors. A rejected candidate
never carries a certificate.

### Checked eventual bounds

Contract 2.4 advertises `check_eventual_bound` with request schema
`check-eventual-bound-request/1`, result schema `eventual-bound-outcome/1`, and
certificate schema `eventual-bound-check/1`.

The initial language is deliberately narrow: nonnegative rational `q`, a
positive natural exponent `k`, and an exact rational upper bound `c` for the
tail `q / (n : ℝ)^k`. A request may supply a positive natural cutoff or ask
the bridge to run LeanCert's bounded exponential search and binary refinement.
Search is untrusted. The bridge emits `verified` only after replaying the final
cutoff through `LeanCert.Validity.checkReciprocalPowerUpper`; the retained
Golden Theorem is `LeanCert.Validity.verify_reciprocal_power_upper`.

The certificate payload records only the exact fixed checker inputs. Search
telemetry records whether the cutoff was supplied or discovered and, for
discovery, its budget, checks, bracket, refinement steps, and completion state.
Rejected supplied cutoffs are `candidate_rejected`; budget exhaustion is
`inconclusive`; tails outside the advertised language are `unsupported`.

### Checked scalar roots

Contract 2.5 advertises `check_scalar_root` with request schema
`check-scalar-root-request/1`, result schema `scalar-root-outcome/1`, and
certificate schema `scalar-root-check/1`. The request supplies one exact
rational interval and selects existence, uniqueness, or exclusion. The bridge
executes respectively `checkSignChange`, `checkNewtonContractsCore`, or
`checkNoRoot`. No root search or subdivision is part of this boundary.

### Checked definite integrals

Contract 2.6 advertises `check_integral` with request schema
`check-integral-request/1`, result schema `integral-outcome/1`, and certificate
schema `integral-check/1`.

Exact equality is limited to the rational-polynomial fragment and is authorized
by `QPoly.checkExactIntegral`. Numerical enclosures are never used to establish
an equality. Lower and upper inequalities use bounded exponential discovery of
a uniform partition count, followed by the fixed
`checkIntegralPartitionLowerBound` or `checkIntegralPartitionUpperBound`
checker. Discovery telemetry is informational; the certificate retains only
the lowered expression, ordered rational interval, relation, rational bound,
and selected partition count.

An incorrect polynomial value or rejected fixed candidate is
`candidate_rejected`, partition exhaustion is `inconclusive`, an evaluation
failure is `domain_obstruction`, and expressions outside the advertised
fragment are `unsupported`.

### Registered downstream enclosures

Contract 2.8 advertises `check_registered_enclosure` and
`replay_registered_enclosure`. These operations are unavailable unless the
profile-specific executable starts with an immutable profile:

```bash
lake env my_profiled_bridge --enclosure-profile profile.json
```

The `leancert-enclosure-profile/1` document names the imported modules, exact
LeanCert revision, downstream environment digest, and explicit allowlist of
unary registered functions. Every named module must be statically imported by
the executable's entry point and declared to `LeanCert.Bridge.run`; the generic
released executable supplies no downstream modules and rejects such a profile.
The Bridge reconstructs this frozen environment once before reading stdin.
`get_info` reports the profile and deterministic registered rule metadata. A
request cannot load modules, mutate the registry, submit raw Lean syntax, or
resolve a declaration outside the allowlist.

`check_registered_enclosure` accepts a structured univariate expression AST.
The `registered` node contains an allowlisted function identifier and a
structured argument; ordinary exact rational arithmetic and supported core
unary operations may surround or occur inside registered calls. The Bridge
constructs a closed Lean proposition over an exact `IntervalRat` and invokes
LeanCert's proof-producing registered-enclosure executor.

Candidate generators remain untrusted discovery code. A verified
`registered-enclosure-check/1` certificate retains:

- the immutable profile identity and exact registry metadata;
- precision, Taylor depth, and configured subdivision depth;
- the complete subdivision tree and leaf domains/results;
- every fixed rule request and output in consumption order;
- composition-step counts.

`replay_registered_enclosure` never invokes a candidate generator. It checks
the certificate's profile identity, resolves each retained rule in the frozen
environment, reruns its Boolean checker on the fixed output, applies the
registered soundness theorem, and reconstructs the complete kernel proof.
Mutated domains, outputs, rule identities, unused entries, or incomplete trees
are rejected.

## Input validity

The bridge rejects zero rational denominators, inverted intervals, and
expressions referencing coordinates outside the supplied box. It never repairs
malformed mathematical input by substituting zero or `[0, 0]`.

## Verification route

`compiled_checker` means the released native bridge evaluated the named
LeanCert Boolean checker and reports its Golden Theorem. It does not claim that
a fresh proof term was elaborated and kernel-reduced for each request.

`kernel_proof` means the Bridge constructed and discharged a fresh Lean goal in
the loaded environment. `fixed_checker_replay` additionally means candidate
search was disabled and only retained checker inputs were consumed.

## Execution provenance

The Bridge reports mathematical capabilities and certificate schemas; it does
not self-report source revisions, dependency locks, or build digests. Execution
hosts such as `lean-runtime` own that supply-chain provenance because they
resolve, hash, build, and execute the exact environment. Enclosure-profile
revision and environment-digest fields remain part of the checked profile input
and are therefore still reported when a profile is loaded.
