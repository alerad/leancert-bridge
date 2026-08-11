/-
Copyright (c) 2024 LeanCert Contributors. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: LeanCert Contributors
-/
import BridgeBuild.RuntimeBase

/-!
# LeanBridge: typed line-delimited JSON bridge for Python integration

This module implements a stateless, typed line-delimited JSON bridge over standard I/O.
The compiled binary acts as a "Math Kernel" or "Oracle" that Python can communicate with.

## Protocol

This is a custom protocol. It is not JSON-RPC 2.0.

### Data Types
- **Rational Numbers:** `{"n": 1, "d": 3}` for 1/3 (exact representation)
- **Expressions:** Recursive JSON objects matching `LeanCert.Core.Expr`
- **Intervals:** `{"lo": Rat, "hi": Rat}`

### Request Format
```json
{ "id": 1, "method": "eval_interval", "params": { "expr": {...}, "box": [...] } }
```

### Response Format
```json
{ "id": 1, "result": { "lo": {...}, "hi": {...} } }
```

## Supported Methods
- `eval_interval`: Evaluate expression over a box using interval arithmetic
- `eval_interval_dyadic`: High-performance evaluation using Dyadic arithmetic (avoids denominator explosion)
- `eval_interval_affine`: Affine arithmetic evaluation (tracks correlations, tighter bounds)
- `global_min`: Find global minimum using branch-and-bound optimization
- `global_max`: Find global maximum using branch-and-bound optimization
- `check_bound`: Verify a bound certificate
- `integrate`: Compute rigorous bounds on a definite integral
- `forward_interval`: Propagate intervals through a neural network (SequentialNet)
-/

open LeanCert.Core LeanCert.Engine LeanCert.Engine.Optimization

-- LExpr is defined in LeanCert.Meta.ProveContinuous (imported via Certificate)
-- to avoid ambiguity with Lean.Expr

namespace LeanCert.Bridge

open Lean

/-! ## 1. Serialization Helpers -/

/-- Bridge contract API version. Major bumps are breaking. -/
def bridgeApiVersion : String := "3.0.0"

/-- Bridge binary version (decoupled from API version). -/
def bridgeVersion : String := "1.1.2"

/-- Lean toolchain version used to build this bridge binary. -/
def leanVersion : String := Lean.versionString

/-- LeanCert release selected by `lakefile.lean`. -/
def leanCertVersion : String := "7486c107f7c2ce814d0914a5f82f7f157ff8bb57"

/-- Certificate/result schema emitted by checked bound operations. -/
def boundCertificateSchema : String := "bound-check/2"

/-- Exact checker-input schema embedded in replayable bound certificates. -/
def boundReplayPayloadSchema : String := "global-opt-bound-replay/1"

/-- Retained non-strict global bound plus exact margin for a strict conclusion. -/
def strictBoundCertificateSchema : String := "strict-bound-check/1"
def strictBoundReplayPayloadSchema : String := "checked-strict-bound/1"

/-- Retained input/result schema for the checked adaptive optimizer. -/
def adaptiveCertificateSchema : String := "adaptive-bound-check/1"
def adaptiveReplayPayloadSchema : String := "checked-global-opt-bound/1"

/-- Retained fixed Krawczyk checker input for unique nonlinear-system roots. -/
def krawczykCertificateSchema : String := "krawczyk-check/1"
def krawczykReplayPayloadSchema : String := "checked-unique-system-root/1"

/-- Retained fixed checker input for reciprocal-power eventual bounds. -/
def eventualCertificateSchema : String := "eventual-bound-check/1"
def eventualReplayPayloadSchema : String := "checked-eventual-bound/1"

/-- Retained fixed checker input for scalar root claims. -/
def scalarRootCertificateSchema : String := "scalar-root-check/1"
def scalarRootReplayPayloadSchema : String := "checked-scalar-root/1"

/-- Fixed registered-enclosure evidence emitted by Contract 2.8. -/
def registeredEnclosureCertificateSchema : String := "registered-enclosure-check/1"
def registeredEnclosureReplayPayloadSchema : String := "checked-registered-enclosure/1"

/-- Retained fixed checker input for exact and bounded definite integrals. -/
def integralCertificateSchema : String := "integral-check/1"
def integralReplayPayloadSchema : String := "checked-integral/1"

/-- Stable request and outcome schemas for the checked bound operation. -/
def boundRequestSchema : String := "check-bound-request/1"
def boundOutcomeSchema : String := "bound-outcome/1"
def strictBoundRequestSchema : String := "check-strict-bound-request/1"
def strictBoundOutcomeSchema : String := "strict-bound-outcome/1"
def adaptiveRequestSchema : String := "verify-adaptive-request/1"
def adaptiveOutcomeSchema : String := "adaptive-bound-outcome/1"
def systemRootRequestSchema : String := "check-unique-system-root-request/1"
def systemRootOutcomeSchema : String := "unique-system-root-outcome/1"
def eventualRequestSchema : String := "check-eventual-bound-request/1"
def eventualOutcomeSchema : String := "eventual-bound-outcome/1"
def scalarRootRequestSchema : String := "check-scalar-root-request/1"
def scalarRootOutcomeSchema : String := "scalar-root-outcome/1"
def integralRequestSchema : String := "check-integral-request/1"
def integralOutcomeSchema : String := "integral-outcome/1"

/-- Raw rational for JSON IO. Uses Int numerator and Nat denominator. -/
structure RawRat where
  n : Int
  d : Nat
  deriving Repr, Inhabited

/-- Convert RawRat to Lean's Rat type. Parsed values always have nonzero denominator. -/
def RawRat.toRat (r : RawRat) : ℚ :=
  if r.d = 0 then 0 else r.n / r.d

instance : FromJson RawRat where
  fromJson? j := do
    let n ← j.getObjValAs? Int "n"
    let d ← j.getObjValAs? Nat "d"
    if d = 0 then
      throw "rational denominator must be nonzero"
    return { n, d }

instance : ToJson RawRat where
  toJson r := Json.mkObj [("n", toJson r.n), ("d", toJson r.d)]

/-- Convert Rat to RawRat for JSON serialization -/
def toRawRat (q : ℚ) : RawRat :=
  { n := q.num, d := q.den }

/-- Raw interval for JSON IO -/
structure RawInterval where
  lo : RawRat
  hi : RawRat
  deriving Repr, Inhabited

instance : FromJson RawInterval where
  fromJson? j := do
    let lo ← j.getObjValAs? RawRat "lo"
    let hi ← j.getObjValAs? RawRat "hi"
    if lo.toRat > hi.toRat then
      throw "interval lower endpoint exceeds upper endpoint"
    return { lo, hi }

instance : ToJson RawInterval where
  toJson i := Json.mkObj [("lo", toJson i.lo), ("hi", toJson i.hi)]

/-- Convert RawInterval to IntervalRat, using default for invalid intervals -/
def RawInterval.toInterval (r : RawInterval) : IntervalRat :=
  let lo := r.lo.toRat
  let hi := r.hi.toRat
  if h : lo ≤ hi then { lo := lo, hi := hi, le := h } else IntervalRat.singleton 0

/-- Convert IntervalRat to RawInterval -/
def toRawInterval (i : IntervalRat) : RawInterval :=
  { lo := toRawRat i.lo, hi := toRawRat i.hi }

/-! ### Immutable registered-enclosure profiles -/

/-- A startup profile explicitly identifies the downstream modules and
registered functions that this process is allowed to expose. -/
structure EnclosureProfile where
  schemaVersion : String
  name : String
  modules : Array String
  allowedFunctions : Array String
  leanCertRevision : String
  environmentDigest : String
  deriving Repr, Inhabited

instance : FromJson EnclosureProfile where
  fromJson? j := do
    let schemaVersion ← j.getObjValAs? String "schema_version"
    unless schemaVersion == "leancert-enclosure-profile/1" do
      throw s!"unsupported enclosure profile schema: {schemaVersion}"
    let name ← j.getObjValAs? String "name"
    let modules ← j.getObjValAs? (Array String) "modules"
    let allowedFunctions ← j.getObjValAs? (Array String) "allowed_functions"
    let leanCertRevision ← j.getObjValAs? String "leancert_revision"
    let environmentDigest ← j.getObjValAs? String "environment_digest"
    if name.isEmpty then throw "enclosure profile name must not be empty"
    if modules.isEmpty then throw "enclosure profile must import at least one module"
    if allowedFunctions.isEmpty then
      throw "enclosure profile must explicitly allow at least one registered function"
    if environmentDigest.isEmpty then throw "enclosure profile environment digest must not be empty"
    return { schemaVersion, name, modules, allowedFunctions, leanCertRevision, environmentDigest }

/-- Frozen environment and deterministic registry selected once at startup. -/
structure EnclosureRuntime where
  profilePath : String
  profile : EnclosureProfile
  environment : Lean.Environment
  rules : Array LeanCert.Tactic.Extension.UnaryEnclosureRule

def profileToJson (runtime : EnclosureRuntime) : Json :=
  Json.mkObj [
    ("schema_version", toJson runtime.profile.schemaVersion),
    ("name", toJson runtime.profile.name),
    ("path", toJson runtime.profilePath),
    ("modules", toJson runtime.profile.modules),
    ("allowed_functions", toJson runtime.profile.allowedFunctions),
    ("leancert_revision", toJson runtime.profile.leanCertRevision),
    ("environment_digest", toJson runtime.profile.environmentDigest),
    ("registry", Json.arr <| runtime.rules.map fun rule => Json.mkObj [
      ("function", toJson rule.functionName.toString),
      ("candidate", toJson rule.candidateName.toString),
      ("checker", toJson rule.checkerName.toString),
      ("theorem", toJson rule.theoremName.toString),
      ("priority", toJson rule.rulePriority)
    ])
  ]

unsafe def loadEnclosureRuntime (path : String)
    (staticProfileModules : Array Name) : IO EnclosureRuntime := do
  let source ← IO.FS.readFile path
  let json ← match Json.parse source with
    | .ok json => pure json
    | .error error => throw <| IO.userError s!"invalid enclosure profile JSON: {error}"
  let profile ← match fromJson? (α := EnclosureProfile) json with
    | .ok profile => pure profile
    | .error error => throw <| IO.userError s!"invalid enclosure profile: {error}"
  unless profile.leanCertRevision == leanCertVersion do
    throw <| IO.userError
      s!"enclosure profile LeanCert revision `{profile.leanCertRevision}` does not match bridge revision `{leanCertVersion}`"
  let profileModules := profile.modules.map String.toName
  for moduleName in profileModules do
    unless staticProfileModules.contains moduleName do
      throw <| IO.userError
        s!"enclosure profile module `{moduleName}` is not statically linked into this Bridge executable (linked modules: {staticProfileModules})"
  Lean.initSearchPath (← Lean.findSysroot)
  Lean.enableInitializersExecution
  let imports := #[{ module := `BridgeBuild.RuntimeBase : Lean.Import }] ++
    profileModules.map fun moduleName => { module := moduleName : Lean.Import }
  let environment ← Lean.importModules (loadExts := true) imports {} 0
  let allRules := LeanCert.Tactic.Extension.getAllUnaryEnclosureRules environment
  let allowed := profile.allowedFunctions.map String.toName
  let rules := allRules.filter fun rule => allowed.contains rule.functionName
  for functionName in allowed do
    unless rules.any fun rule => rule.functionName == functionName do
      throw <| IO.userError
        s!"enclosure profile allows `{functionName}` but no imported rule registers it"
  return { profilePath := path, profile, environment, rules }

/-! ### Safe registered-expression request AST -/

inductive RegisteredExpr where
  | rational (value : RawRat)
  | variable
  | neg (value : RegisteredExpr)
  | add (left right : RegisteredExpr)
  | sub (left right : RegisteredExpr)
  | mul (left right : RegisteredExpr)
  | div (left right : RegisteredExpr)
  | pow (base : RegisteredExpr) (exponent : Nat)
  | builtin (name : String) (argument : RegisteredExpr)
  | registered (functionName : String) (argument : RegisteredExpr)
  deriving Repr, Inhabited

partial def registeredExprFromJson (j : Json) : Except String RegisteredExpr := do
  let kind ← j.getObjValAs? String "kind"
  match kind with
  | "const" => return .rational (← j.getObjValAs? RawRat "val")
  | "var" =>
      let idx ← j.getObjValAs? Nat "idx"
      unless idx == 0 do throw "registered enclosure expressions are univariate; expected var 0"
      return .variable
  | "neg" => return .neg (← registeredExprFromJson (← j.getObjVal? "e"))
  | "add" => return (.add
      (← registeredExprFromJson (← j.getObjVal? "e1"))
      (← registeredExprFromJson (← j.getObjVal? "e2")))
  | "sub" => return (.sub
      (← registeredExprFromJson (← j.getObjVal? "e1"))
      (← registeredExprFromJson (← j.getObjVal? "e2")))
  | "mul" => return (.mul
      (← registeredExprFromJson (← j.getObjVal? "e1"))
      (← registeredExprFromJson (← j.getObjVal? "e2")))
  | "div" => return (.div
      (← registeredExprFromJson (← j.getObjVal? "e1"))
      (← registeredExprFromJson (← j.getObjVal? "e2")))
  | "pow" => return (.pow
      (← registeredExprFromJson (← j.getObjVal? "base"))
      (← j.getObjValAs? Nat "exp"))
  | "registered" => return (.registered
      (← j.getObjValAs? String "function")
      (← registeredExprFromJson (← j.getObjVal? "argument")))
  | name =>
      if #["sin", "cos", "exp", "log", "sqrt", "inv", "atan", "arsinh",
          "atanh", "sinc", "erf", "abs", "sinh", "cosh", "tanh"].contains name then
        return .builtin name (← registeredExprFromJson (← j.getObjVal? "e"))
      throw s!"unknown registered enclosure expression kind: {name}"

instance : FromJson RegisteredExpr where
  fromJson? := registeredExprFromJson

structure CheckRegisteredEnclosureRequest where
  expression : RegisteredExpr
  domain : RawInterval
  relation : String
  bound : RawRat
  precision : Int := -53
  taylorDepth : Nat := 10
  maxDepth : Nat := 4
  deriving Repr, Inhabited

instance : FromJson CheckRegisteredEnclosureRequest where
  fromJson? j := do
    let expression ← j.getObjValAs? RegisteredExpr "expression"
    let domain ← j.getObjValAs? RawInterval "domain"
    let relation ← j.getObjValAs? String "relation"
    unless #["le", "lt", "ge", "gt"].contains relation do
      throw "registered enclosure relation must be one of: le, lt, ge, gt"
    let bound ← j.getObjValAs? RawRat "bound"
    let precision := (j.getObjValAs? Int "precision").toOption.getD (-53)
    let taylorDepth := (j.getObjValAs? Nat "taylor_depth").toOption.getD 10
    let maxDepth := (j.getObjValAs? Nat "max_depth").toOption.getD 4
    return { expression, domain, relation, bound, precision, taylorDepth, maxDepth }

private def enclosureRuleFromJson (j : Json) : Except String
    LeanCert.Tactic.Extension.UnaryEnclosureRule := do
  return {
    functionName := (← j.getObjValAs? String "function").toName
    candidateName := (← j.getObjValAs? String "candidate").toName
    checkerName := (← j.getObjValAs? String "checker").toName
    theoremName := (← j.getObjValAs? String "theorem").toName
    rulePriority := ← j.getObjValAs? Nat "priority"
  }

private def enclosureEntryFromJson (j : Json) : Except String
    LeanCert.Tactic.Extension.RegisteredEnclosureCertificateEntry := do
  let rule ← enclosureRuleFromJson (← j.getObjVal? "rule")
  let requestJson ← j.getObjVal? "request"
  let input ← requestJson.getObjValAs? RawInterval "input"
  let precision ← requestJson.getObjValAs? Int "precision"
  let taylorDepth ← requestJson.getObjValAs? Nat "taylor_depth"
  let output ← j.getObjValAs? RawInterval "output"
  return {
    rule
    request := { input := input.toInterval, precision, taylorDepth }
    output := output.toInterval
  }

private partial def enclosureTreeFromJson (j : Json) : Except String
    LeanCert.Tactic.Extension.RegisteredEnclosureCertificateTree := do
  let kind ← j.getObjValAs? String "kind"
  let input := (← j.getObjValAs? RawInterval "input").toInterval
  match kind with
  | "leaf" =>
      let output := (← j.getObjValAs? RawInterval "output").toInterval
      let entriesJson ← j.getObjValAs? (Array Json) "entries"
      let entries ← entriesJson.mapM enclosureEntryFromJson
      let compositionSteps ← j.getObjValAs? Nat "composition_steps"
      return .leaf input output entries compositionSteps
  | "bisect" =>
      let left ← enclosureTreeFromJson (← j.getObjVal? "left")
      let right ← enclosureTreeFromJson (← j.getObjVal? "right")
      return .bisect input left right
  | other => throw s!"unknown registered enclosure certificate node: {other}"

structure RetainedEnclosureCertificate where
  profileName : String
  leanCertRevision : String
  environmentDigest : String
  certificate : LeanCert.Tactic.Extension.RegisteredEnclosureCertificate

private def retainedEnclosureCertificateFromJson (j : Json) : Except String
    RetainedEnclosureCertificate := do
  let schema ← j.getObjValAs? String "schema"
  unless schema == registeredEnclosureCertificateSchema do
    throw s!"unsupported registered enclosure certificate schema: {schema}"
  let profile ← j.getObjVal? "profile"
  let profileName ← profile.getObjValAs? String "name"
  let leanCertRevision ← profile.getObjValAs? String "leancert_revision"
  let environmentDigest ← profile.getObjValAs? String "environment_digest"
  let precision ← j.getObjValAs? Int "precision"
  let taylorDepth ← j.getObjValAs? Nat "taylor_depth"
  let configuredMaxDepth ← j.getObjValAs? Nat "configured_max_depth"
  let tree ← enclosureTreeFromJson (← j.getObjVal? "tree")
  return {
    profileName
    leanCertRevision
    environmentDigest
    certificate := { precision, taylorDepth, configuredMaxDepth, tree }
  }

structure ReplayRegisteredEnclosureRequest where
  claim : CheckRegisteredEnclosureRequest
  retained : RetainedEnclosureCertificate

instance : FromJson ReplayRegisteredEnclosureRequest where
  fromJson? j := do
    let claim ← FromJson.fromJson? (α := CheckRegisteredEnclosureRequest)
      (← j.getObjVal? "claim")
    let retained ← retainedEnclosureCertificateFromJson (← j.getObjVal? "certificate")
    return { claim, retained }

/-! ### Dyadic Serialization -/

/-- Raw Dyadic for JSON IO. Uses mantissa and exponent. -/
structure RawDyadic where
  mantissa : Int
  exponent : Int
  deriving Repr, Inhabited

instance : FromJson RawDyadic where
  fromJson? j := do
    let mantissa ← j.getObjValAs? Int "mantissa"
    let exponent ← j.getObjValAs? Int "exponent"
    return { mantissa, exponent }

instance : ToJson RawDyadic where
  toJson d := Json.mkObj [("mantissa", toJson d.mantissa), ("exponent", toJson d.exponent)]

/-- Convert RawDyadic to Dyadic -/
def RawDyadic.toDyadic (r : RawDyadic) : Core.Dyadic :=
  { mantissa := r.mantissa, exponent := r.exponent }

/-- Convert Dyadic to RawDyadic -/
def toRawDyadic (d : Core.Dyadic) : RawDyadic :=
  { mantissa := d.mantissa, exponent := d.exponent }

/-- Raw Dyadic interval for JSON IO -/
structure RawDyadicInterval where
  lo : RawDyadic
  hi : RawDyadic
  deriving Repr, Inhabited

instance : FromJson RawDyadicInterval where
  fromJson? j := do
    let lo ← j.getObjValAs? RawDyadic "lo"
    let hi ← j.getObjValAs? RawDyadic "hi"
    if lo.toDyadic.toRat > hi.toDyadic.toRat then
      throw "dyadic interval lower endpoint exceeds upper endpoint"
    return { lo, hi }

instance : ToJson RawDyadicInterval where
  toJson i := Json.mkObj [("lo", toJson i.lo), ("hi", toJson i.hi)]

/-- Convert RawDyadicInterval to IntervalDyadic, using default for invalid intervals -/
def RawDyadicInterval.toInterval (r : RawDyadicInterval) : Core.IntervalDyadic :=
  let lo := r.lo.toDyadic
  let hi := r.hi.toDyadic
  if h : lo.toRat ≤ hi.toRat then { lo := lo, hi := hi, le := h }
  else Core.IntervalDyadic.singleton Core.Dyadic.zero

/-- Convert IntervalDyadic to RawDyadicInterval -/
def toRawDyadicInterval (i : Core.IntervalDyadic) : RawDyadicInterval :=
  { lo := toRawDyadic i.lo, hi := toRawDyadic i.hi }

/-- Dyadic configuration for JSON IO -/
structure RawDyadicConfig where
  precision : Int := -53
  taylorDepth : Nat := 10
  roundAfterOps : Nat := 0
  deriving Repr, Inhabited

instance : FromJson RawDyadicConfig where
  fromJson? j := do
    let precision := (j.getObjValAs? Int "precision").toOption.getD (-53)
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    let roundAfterOps := (j.getObjValAs? Nat "roundAfterOps").toOption.getD 0
    return { precision, taylorDepth, roundAfterOps }

instance : ToJson RawDyadicConfig where
  toJson c := Json.mkObj [
    ("precision", toJson c.precision),
    ("taylorDepth", toJson c.taylorDepth),
    ("roundAfterOps", toJson c.roundAfterOps)
  ]

/-- Convert RawDyadicConfig to DyadicConfig -/
def RawDyadicConfig.toDyadicConfig (r : RawDyadicConfig) : DyadicConfig :=
  { precision := r.precision, taylorDepth := r.taylorDepth }

/-! ### Affine Config Serialization -/

/-- Affine configuration for JSON IO -/
structure RawAffineConfig where
  taylorDepth : Nat := 10
  maxNoiseSymbols : Nat := 0
  deriving Repr, Inhabited

instance : FromJson RawAffineConfig where
  fromJson? j := do
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    let maxNoiseSymbols := (j.getObjValAs? Nat "maxNoiseSymbols").toOption.getD 0
    return { taylorDepth, maxNoiseSymbols }

instance : ToJson RawAffineConfig where
  toJson c := Json.mkObj [
    ("taylorDepth", toJson c.taylorDepth),
    ("maxNoiseSymbols", toJson c.maxNoiseSymbols)
  ]

/-- Convert RawAffineConfig to AffineConfig -/
def RawAffineConfig.toAffineConfig (r : RawAffineConfig) : AffineConfig :=
  { taylorDepth := r.taylorDepth, maxNoiseSymbols := r.maxNoiseSymbols }

/-! ## 2. Expression Deserialization -/

/-- Recursive FromJson for LExpr AST -/
partial def rawExprFromJson (j : Json) : Except String LExpr := do
  let kind ← j.getObjValAs? String "kind"
  match kind with
  | "const" =>
    let q ← j.getObjValAs? RawRat "val"
    return Expr.const q.toRat
  | "var" =>
    let idx ← j.getObjValAs? Nat "idx"
    return Expr.var idx
  | "neg" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.neg e
  | "add" =>
    let e1 ← rawExprFromJson (← j.getObjVal? "e1")
    let e2 ← rawExprFromJson (← j.getObjVal? "e2")
    return Expr.add e1 e2
  | "sub" =>
    let e1 ← rawExprFromJson (← j.getObjVal? "e1")
    let e2 ← rawExprFromJson (← j.getObjVal? "e2")
    return Expr.add e1 (Expr.neg e2)  -- Desugar to add + neg
  | "mul" =>
    let e1 ← rawExprFromJson (← j.getObjVal? "e1")
    let e2 ← rawExprFromJson (← j.getObjVal? "e2")
    return Expr.mul e1 e2
  | "div" =>
    let e1 ← rawExprFromJson (← j.getObjVal? "e1")
    let e2 ← rawExprFromJson (← j.getObjVal? "e2")
    return Expr.div e1 e2
  | "sin" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.sin e
  | "cos" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.cos e
  | "exp" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.exp e
  | "log" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.log e
  | "pow" =>
    -- Integer power: pow(e, n) where n is a natural number
    let base ← rawExprFromJson (← j.getObjVal? "base")
    let exp ← j.getObjValAs? Nat "exp"
    return Expr.pow base exp
  | "sqrt" =>
    -- sqrt(x) = exp(log(x)/2) for positive x
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.exp (Expr.div (Expr.log e) (Expr.const 2))
  | "inv" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.inv e
  | "tan" =>
    -- tan(x) = sin(x) / cos(x)
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.div (Expr.sin e) (Expr.cos e)
  | "atan" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.atan e
  | "arsinh" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.arsinh e
  | "atanh" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.atanh e
  | "sinc" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.sinc e
  | "erf" =>
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.erf e
  | "abs" =>
    -- |x| = sqrt(x²) (derived definition from Expr.lean)
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.abs e
  | "sinh" =>
    -- Native sinh expression with proper interval bounds
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.sinh e
  | "cosh" =>
    -- Native cosh expression with cosh(x) ≥ 1 bounds
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.cosh e
  | "tanh" =>
    -- Native tanh expression with tight [-1, 1] bounds (no interval explosion!)
    let e ← rawExprFromJson (← j.getObjVal? "e")
    return Expr.tanh e
  | "min" =>
    -- min(a, b) = (a + b - |a - b|) / 2
    let e1 ← rawExprFromJson (← j.getObjVal? "e1")
    let e2 ← rawExprFromJson (← j.getObjVal? "e2")
    let diff := Expr.add e1 (Expr.neg e2)
    let absDiff := Expr.abs diff
    return Expr.div (Expr.add (Expr.add e1 e2) (Expr.neg absDiff)) (Expr.const 2)
  | "max" =>
    -- max(a, b) = (a + b + |a - b|) / 2
    let e1 ← rawExprFromJson (← j.getObjVal? "e1")
    let e2 ← rawExprFromJson (← j.getObjVal? "e2")
    let diff := Expr.add e1 (Expr.neg e2)
    let absDiff := Expr.abs diff
    return Expr.div (Expr.add (Expr.add e1 e2) absDiff) (Expr.const 2)
  | other => throw s!"Unknown expression kind: {other}"

instance : FromJson LExpr where
  fromJson? := rawExprFromJson

/-- Canonical serialization of the expression value actually checked. Derived
request syntax such as subtraction, division, powers, min, and max has already
been lowered to LeanCert's core expression constructors at this boundary. -/
partial def exprToJson : LExpr → Json
  | .const q => Json.mkObj [("kind", toJson "const"), ("val", toJson (toRawRat q))]
  | .var idx => Json.mkObj [("kind", toJson "var"), ("idx", toJson idx)]
  | .add e₁ e₂ => Json.mkObj [
      ("kind", toJson "add"), ("e1", exprToJson e₁), ("e2", exprToJson e₂)]
  | .mul e₁ e₂ => Json.mkObj [
      ("kind", toJson "mul"), ("e1", exprToJson e₁), ("e2", exprToJson e₂)]
  | .neg e => Json.mkObj [("kind", toJson "neg"), ("e", exprToJson e)]
  | .inv e => Json.mkObj [("kind", toJson "inv"), ("e", exprToJson e)]
  | .exp e => Json.mkObj [("kind", toJson "exp"), ("e", exprToJson e)]
  | .sin e => Json.mkObj [("kind", toJson "sin"), ("e", exprToJson e)]
  | .cos e => Json.mkObj [("kind", toJson "cos"), ("e", exprToJson e)]
  | .log e => Json.mkObj [("kind", toJson "log"), ("e", exprToJson e)]
  | .atan e => Json.mkObj [("kind", toJson "atan"), ("e", exprToJson e)]
  | .arsinh e => Json.mkObj [("kind", toJson "arsinh"), ("e", exprToJson e)]
  | .atanh e => Json.mkObj [("kind", toJson "atanh"), ("e", exprToJson e)]
  | .sinc e => Json.mkObj [("kind", toJson "sinc"), ("e", exprToJson e)]
  | .erf e => Json.mkObj [("kind", toJson "erf"), ("e", exprToJson e)]
  | .sinh e => Json.mkObj [("kind", toJson "sinh"), ("e", exprToJson e)]
  | .cosh e => Json.mkObj [("kind", toJson "cosh"), ("e", exprToJson e)]
  | .tanh e => Json.mkObj [("kind", toJson "tanh"), ("e", exprToJson e)]
  | .sqrt e => Json.mkObj [("kind", toJson "sqrt"), ("e", exprToJson e)]
  | .namedConst .pi => Json.mkObj [("kind", toJson "named_const"), ("name", toJson "pi")]
  | .namedConst .eulerMascheroni =>
      Json.mkObj [("kind", toJson "named_const"), ("name", toJson "euler_mascheroni")]

/-- Reject requests whose expression refers to a coordinate absent from the box.
Out-of-range variables must not be silently interpreted as zero at the protocol boundary. -/
def exprVarsInRange (dimension : Nat) : LExpr → Bool
  | .const _ | .namedConst _ => true
  | .var i => i < dimension
  | .add e₁ e₂ | .mul e₁ e₂ => exprVarsInRange dimension e₁ && exprVarsInRange dimension e₂
  | .neg e | .inv e | .exp e | .sin e | .cos e | .log e | .atan e | .arsinh e
  | .atanh e | .sinc e | .erf e | .sinh e | .cosh e | .tanh e | .sqrt e =>
      exprVarsInRange dimension e

def validateExprBox (expr : LExpr) (box : Array RawInterval) : Except String Unit := do
  if exprVarsInRange box.size expr then
    return ()
  throw s!"expression references a variable outside box dimension {box.size}"

def validatePositive (name : String) (value : RawRat) : Except String Unit := do
  if 0 < value.toRat then return ()
  throw s!"{name} must be positive"

/-- Executable reflection of the `ExprSupported` subset required by the
published global-optimization Golden Theorems. -/
def isGloballyOptimizable : LExpr → Bool
  | .const _ | .var _ => true
  | .add e₁ e₂ | .mul e₁ e₂ => isGloballyOptimizable e₁ && isGloballyOptimizable e₂
  | .neg e | .exp e | .sin e | .cos e => isGloballyOptimizable e
  | _ => false

/-! ## 3. Request Structures -/

/-- Request for interval evaluation -/
structure EvalRequest where
  expr : LExpr
  box  : Array RawInterval
  taylorDepth : Nat := 10

instance : FromJson EvalRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, box := boxArr, taylorDepth }

/-- Request for global optimization -/
structure OptimizeRequest where
  expr : LExpr
  box  : Array RawInterval
  maxIters : Nat := 1000
  tolerance : RawRat := { n := 1, d := 1000 }
  useMonotonicity : Bool := true
  taylorDepth : Nat := 10

instance : FromJson OptimizeRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let maxIters := (j.getObjValAs? Nat "maxIters").toOption.getD 1000
    let tolerance := (j.getObjValAs? RawRat "tolerance").toOption.getD { n := 1, d := 1000 }
    validatePositive "tolerance" tolerance
    let useMonotonicity := (j.getObjValAs? Bool "useMonotonicity").toOption.getD true
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, box := boxArr, maxIters, tolerance, useMonotonicity, taylorDepth }

/-- Request for bound checking -/
structure CheckBoundRequest where
  expr : LExpr
  box  : Array RawInterval
  bound : RawRat
  isUpperBound : Bool  -- true for upper bound, false for lower bound
  taylorDepth : Nat := 10

instance : FromJson CheckBoundRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let bound ← j.getObjValAs? RawRat "bound"
    let isUpperBound ← j.getObjValAs? Bool "isUpperBound"
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, box := boxArr, bound, isUpperBound, taylorDepth }

/-- Request for a strict global bound. `lt` means `expr < bound`; `gt` means
    `bound < expr`. The retained certificate proves an interior non-strict
    bound and composes it with an exact rational margin. -/
structure CheckStrictBoundRequest where
  expr : LExpr
  box : Array RawInterval
  bound : RawRat
  relation : String
  taylorDepth : Nat := 10

instance : FromJson CheckStrictBoundRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let bound ← j.getObjValAs? RawRat "bound"
    let relation ← j.getObjValAs? String "relation"
    if relation != "lt" && relation != "gt" then
      throw "strict bound relation must be one of: lt, gt"
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, box := boxArr, bound, relation, taylorDepth }

/-- Request for numerical integration -/
structure IntegrateRequest where
  expr : LExpr
  interval : RawInterval
  partitions : Nat := 10
  taylorDepth : Nat := 10

instance : FromJson IntegrateRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let interval ← j.getObjValAs? RawInterval "interval"
    let partitions := (j.getObjValAs? Nat "partitions").toOption.getD 10
    if partitions == 0 then throw "partitions must be positive"
    if !exprVarsInRange 1 expr then throw "integration expressions may only reference variable 0"
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, interval, partitions, taylorDepth }

/-- Semantic definite-integral claim. Equality uses the exact rational-polynomial
    checker. Lower and upper claims use untrusted partition discovery followed
    by one retained fixed-candidate checker. -/
structure CheckIntegralRequest where
  expr : LExpr
  interval : RawInterval
  relation : String
  bound : RawRat
  startPartitions : Nat := 32
  maxPartitions : Nat := 4096
  deriving Repr, Inhabited

instance : FromJson CheckIntegralRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let interval ← j.getObjValAs? RawInterval "interval"
    let relation ← j.getObjValAs? String "relation"
    if relation != "eq" && relation != "lower" && relation != "upper" then
      throw "relation must be one of: eq, lower, upper"
    let bound ← j.getObjValAs? RawRat "bound"
    let startPartitions := (j.getObjValAs? Nat "startPartitions").toOption.getD 32
    let maxPartitions := (j.getObjValAs? Nat "maxPartitions").toOption.getD 4096
    if startPartitions == 0 then throw "startPartitions must be positive"
    if maxPartitions < startPartitions then
      throw "maxPartitions must be at least startPartitions"
    if interval.toInterval.hi < interval.toInterval.lo then
      throw "integration interval endpoints must be ordered"
    if !exprVarsInRange 1 expr then
      throw "integration expressions may only reference variable 0"
    return { expr, interval, relation, bound, startPartitions, maxPartitions }

/-- Request for root finding -/
structure FindRootsRequest where
  expr : LExpr
  interval : RawInterval
  maxIter : Nat := 1000
  tolerance : RawRat := { n := 1, d := 1000 }
  taylorDepth : Nat := 10

instance : FromJson FindRootsRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let interval ← j.getObjValAs? RawInterval "interval"
    let maxIter := (j.getObjValAs? Nat "maxIter").toOption.getD 1000
    let tolerance := (j.getObjValAs? RawRat "tolerance").toOption.getD { n := 1, d := 1000 }
    validatePositive "tolerance" tolerance
    if !exprVarsInRange 1 expr then throw "root expressions may only reference variable 0"
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, interval, maxIter, tolerance, taylorDepth }

/-- Request for unique root finding via Newton contraction -/
structure FindUniqueRootRequest where
  expr : LExpr
  interval : RawInterval
  taylorDepth : Nat := 10

instance : FromJson FindUniqueRootRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let interval ← j.getObjValAs? RawInterval "interval"
    if !exprVarsInRange 1 expr then throw "root expressions may only reference variable 0"
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, interval, taylorDepth }

/-- Fixed scalar-root claim. Search and subdivision remain separate from this
    proof boundary; the supplied interval is checked exactly as furnished. -/
structure CheckScalarRootRequest where
  expr : LExpr
  interval : RawInterval
  claim : String
  taylorDepth : Nat := 10
  deriving Repr, Inhabited

instance : FromJson CheckScalarRootRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let interval ← j.getObjValAs? RawInterval "interval"
    let claim ← j.getObjValAs? String "claim"
    if claim != "exists" && claim != "unique" && claim != "excluded" then
      throw "claim must be one of: exists, unique, excluded"
    if !exprVarsInRange 1 expr then throw "root expressions may only reference variable 0"
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, interval, claim, taylorDepth }

/-- Optional exact candidate supplied by an untrusted external numerical solver. -/
structure RawKrawczykCandidate where
  center : Array RawRat
  preconditioner : Array (Array RawRat)
  deriving Repr, Inhabited

instance : FromJson RawKrawczykCandidate where
  fromJson? j := do
    let centerJson ← j.getObjVal? "center"
    let center ← match centerJson with
      | Json.arr values => values.mapM (FromJson.fromJson? (α := RawRat))
      | _ => throw "candidate center must be an array"
    let matrixJson ← j.getObjVal? "preconditioner"
    let preconditioner ← match matrixJson with
      | Json.arr rows => rows.mapM fun row => match row with
          | Json.arr values => values.mapM (FromJson.fromJson? (α := RawRat))
          | _ => throw "candidate preconditioner rows must be arrays"
      | _ => throw "candidate preconditioner must be an array"
    return { center, preconditioner }

/-- Checked unique-system-root request. Candidate construction is untrusted;
    only `krawczykCheck` controls the `verified` outcome. -/
structure CheckUniqueSystemRootRequest where
  system : Array LExpr
  box : Array RawInterval
  candidate : Option RawKrawczykCandidate := none
  maxIterations : Nat := 8
  maxDimension : Nat := 4
  precisionBits : Nat := 20
  taylorDepth : Nat := 10
  deriving Repr, Inhabited

instance : FromJson CheckUniqueSystemRootRequest where
  fromJson? j := do
    let systemJson ← j.getObjVal? "system"
    let system ← match systemJson with
      | Json.arr values => values.mapM (FromJson.fromJson? (α := LExpr))
      | _ => throw "system must be an array"
    let boxJson ← j.getObjVal? "box"
    let box ← match boxJson with
      | Json.arr values => values.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    if system.isEmpty then throw "system dimension must be positive"
    if system.size != box.size then
      throw s!"system dimension {system.size} does not match box dimension {box.size}"
    for expression in system do
      if !exprVarsInRange box.size expression then
        throw s!"system expression references a variable outside box dimension {box.size}"
    let candidate ← match j.getObjVal? "candidate" with
      | Except.error _ => pure none
      | Except.ok Json.null => pure none
      | Except.ok value => some <$> FromJson.fromJson? value
    match candidate with
    | none => pure ()
    | some value =>
        if value.center.size != box.size then
          throw s!"candidate center dimension {value.center.size} does not match system dimension {box.size}"
        if value.preconditioner.size != box.size then
          throw s!"candidate preconditioner has {value.preconditioner.size} rows; expected {box.size}"
        for row in value.preconditioner do
          if row.size != box.size then
            throw s!"candidate preconditioner row has dimension {row.size}; expected {box.size}"
    let maxIterations := (j.getObjValAs? Nat "maxIterations").toOption.getD 8
    let maxDimension := (j.getObjValAs? Nat "maxDimension").toOption.getD 4
    let precisionBits := (j.getObjValAs? Nat "precisionBits").toOption.getD 20
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { system, box, candidate, maxIterations, maxDimension, precisionBits, taylorDepth }

/-- Checked reciprocal-power eventual-bound request. Cutoff discovery is
    untrusted; only `checkReciprocalPowerUpper` controls verification. -/
structure CheckEventualBoundRequest where
  coefficient : RawRat
  bound : RawRat
  exponent : Nat
  cutoff : Option Nat := none
  maxChecks : Nat := 1000
  deriving Repr, Inhabited

instance : FromJson CheckEventualBoundRequest where
  fromJson? j := do
    let coefficient ← j.getObjValAs? RawRat "coefficient"
    let bound ← j.getObjValAs? RawRat "bound"
    let exponent ← j.getObjValAs? Nat "exponent"
    let cutoff ← match j.getObjVal? "cutoff" with
      | Except.error _ => pure none
      | Except.ok Json.null => pure none
      | Except.ok value => some <$> FromJson.fromJson? value
    let maxChecks := (j.getObjValAs? Nat "maxChecks").toOption.getD 1000
    if maxChecks = 0 then throw "maxChecks must be positive"
    return { coefficient, bound, exponent, cutoff, maxChecks }

/-- Telemetry from untrusted bridge-side cutoff discovery. -/
structure EventualSearchStatistics where
  cutoff : Nat
  checks : Nat
  configuredLimit : Nat
  exponentialSteps : Nat
  refinementSteps : Nat
  lowerBracket : Nat
  upperBracket : Nat
  refinementComplete : Bool
  deriving Repr, Inhabited

private partial def exponentialCutoffSearch (q bound : ℚ) (k : Nat)
    (limit checks lo hi steps : Nat) : Except (Nat × Nat) (Nat × Nat × Nat × Nat) :=
  if checks ≥ limit then .error (checks, lo)
  else if LeanCert.Validity.checkReciprocalPowerUpper q bound k hi then
    .ok (lo, hi, checks + 1, steps + 1)
  else exponentialCutoffSearch q bound k limit (checks + 1) hi (2 * hi) (steps + 1)

private partial def refineCutoff (q bound : ℚ) (k limit : Nat)
    (checks lo hi steps : Nat) : Nat × Nat × Nat × Nat × Bool :=
  if lo + 1 ≥ hi then (lo, hi, checks, steps, true)
  else if checks ≥ limit then (lo, hi, checks, steps, false)
  else
    let mid := (lo + hi) / 2
    if LeanCert.Validity.checkReciprocalPowerUpper q bound k mid then
      refineCutoff q bound k limit (checks + 1) lo mid (steps + 1)
    else
      refineCutoff q bound k limit (checks + 1) mid hi (steps + 1)

/-- Deterministic but untrusted cutoff discovery. Its output must always be
    replayed through `checkReciprocalPowerUpper`. -/
def discoverEventualCutoff (q bound : ℚ) (k maxChecks : Nat) :
    Except (Nat × Nat) EventualSearchStatistics := do
  if LeanCert.Validity.checkReciprocalPowerUpper q bound k 1 then
    return {
      cutoff := 1, checks := 1, configuredLimit := maxChecks,
      exponentialSteps := 0, refinementSteps := 0,
      lowerBracket := 0, upperBracket := 1, refinementComplete := true
    }
  let (lo, hi, checks, exponentialSteps) ←
    exponentialCutoffSearch q bound k maxChecks 1 1 2 0
  let (lo, hi, checks, refinementSteps, complete) :=
    refineCutoff q bound k maxChecks checks lo hi 0
  return {
    cutoff := hi, checks, configuredLimit := maxChecks, exponentialSteps,
    refinementSteps, lowerBracket := lo, upperBracket := hi,
    refinementComplete := complete
  }

/-- Request for adaptive verification using optimization -/
structure VerifyAdaptiveRequest where
  expr : LExpr
  box : Array RawInterval
  bound : RawRat
  isUpperBound : Bool
  maxIters : Nat := 1000
  tolerance : RawRat := { n := 1, d := 1000 }
  taylorDepth : Nat := 10

instance : FromJson VerifyAdaptiveRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let bound ← j.getObjValAs? RawRat "bound"
    let isUpperBound ← j.getObjValAs? Bool "isUpperBound"
    let maxIters := (j.getObjValAs? Nat "maxIters").toOption.getD 1000
    let tolerance := (j.getObjValAs? RawRat "tolerance").toOption.getD { n := 1, d := 1000 }
    validatePositive "tolerance" tolerance
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, box := boxArr, bound, isUpperBound, maxIters, tolerance, taylorDepth }

/-- Request for high-performance Dyadic interval evaluation -/
structure EvalDyadicRequest where
  expr : LExpr
  box  : Array RawInterval
  config : RawDyadicConfig := {}

instance : FromJson EvalDyadicRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let config := (j.getObjValAs? RawDyadicConfig "config").toOption.getD {}
    return { expr, box := boxArr, config }

/-- Request for Affine interval evaluation (tracks correlations) -/
structure EvalAffineRequest where
  expr : LExpr
  box  : Array RawInterval
  config : RawAffineConfig := {}

instance : FromJson EvalAffineRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let config := (j.getObjValAs? RawAffineConfig "config").toOption.getD {}
    return { expr, box := boxArr, config }

/-- Request for global optimization with Dyadic backend -/
structure OptimizeDyadicRequest where
  expr : LExpr
  box  : Array RawInterval
  maxIters : Nat := 1000
  tolerance : RawRat := { n := 1, d := 1000 }
  useMonotonicity : Bool := true
  taylorDepth : Nat := 10
  precision : Int := -53

instance : FromJson OptimizeDyadicRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let maxIters := (j.getObjValAs? Nat "maxIters").toOption.getD 1000
    let tolerance := (j.getObjValAs? RawRat "tolerance").toOption.getD { n := 1, d := 1000 }
    validatePositive "tolerance" tolerance
    let useMonotonicity := (j.getObjValAs? Bool "useMonotonicity").toOption.getD true
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    let precision := (j.getObjValAs? Int "precision").toOption.getD (-53)
    return { expr, box := boxArr, maxIters, tolerance, useMonotonicity, taylorDepth, precision }

/-- Request for global optimization with Affine backend -/
structure OptimizeAffineRequest where
  expr : LExpr
  box  : Array RawInterval
  maxIters : Nat := 1000
  tolerance : RawRat := { n := 1, d := 1000 }
  useMonotonicity : Bool := true
  taylorDepth : Nat := 10
  maxNoiseSymbols : Nat := 0

instance : FromJson OptimizeAffineRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let maxIters := (j.getObjValAs? Nat "maxIters").toOption.getD 1000
    let tolerance := (j.getObjValAs? RawRat "tolerance").toOption.getD { n := 1, d := 1000 }
    validatePositive "tolerance" tolerance
    let useMonotonicity := (j.getObjValAs? Bool "useMonotonicity").toOption.getD true
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    let maxNoiseSymbols := (j.getObjValAs? Nat "maxNoiseSymbols").toOption.getD 0
    return { expr, box := boxArr, maxIters, tolerance, useMonotonicity, taylorDepth, maxNoiseSymbols }

/-! ### Neural Network Forward Interval Request -/

/-- A raw layer for JSON deserialization -/
structure RawLayer where
  weights : Array (Array RawRat)
  bias : Array RawRat
  deriving Repr, Inhabited

instance : FromJson RawLayer where
  fromJson? j := do
    let rawWeights ← j.getObjValAs? (Array (Array RawRat)) "weights"
    let rawBias ← j.getObjValAs? (Array RawRat) "bias"
    return { weights := rawWeights, bias := rawBias }

/-- Convert RawLayer to ML.Layer -/
def RawLayer.toLayer (r : RawLayer) : LeanCert.ML.Layer where
  weights := r.weights.toList.map (fun row => row.toList.map RawRat.toRat)
  bias := r.bias.toList.map RawRat.toRat

/-- Request for neural network forward interval propagation -/
structure ForwardIntervalRequest where
  layers : Array RawLayer
  input : Array RawInterval
  precision : Int := -53
  deriving Repr, Inhabited

instance : FromJson ForwardIntervalRequest where
  fromJson? j := do
    let layers ← j.getObjValAs? (Array RawLayer) "layers"
    let input ← j.getObjValAs? (Array RawInterval) "input"
    let precision := (j.getObjValAs? Int "precision").toOption.getD (-53)
    return { layers, input, precision }

/-- Request for derivative interval evaluation (for Lipschitz bounds).
    Computes bounds on all partial derivatives over a box. -/
structure DerivIntervalRequest where
  expr : LExpr
  box : Array RawInterval
  taylorDepth : Nat := 10

instance : FromJson DerivIntervalRequest where
  fromJson? j := do
    let expr ← j.getObjValAs? LExpr "expr"
    let boxJson ← j.getObjVal? "box"
    let boxArr ← match boxJson with
      | Json.arr arr => arr.mapM (FromJson.fromJson? (α := RawInterval))
      | _ => throw "box must be an array"
    validateExprBox expr boxArr
    let taylorDepth := (j.getObjValAs? Nat "taylorDepth").toOption.getD 10
    return { expr, box := boxArr, taylorDepth }

/-! ## 4. Request Handlers -/

def boundReplayPayloadJson (req : CheckBoundRequest) (cfg : GlobalOptConfig) : Json :=
  Json.mkObj [
    ("schema_version", toJson boundReplayPayloadSchema),
    ("expression", exprToJson req.expr),
    ("box", toJson (req.box.map fun interval => toRawInterval interval.toInterval)),
    ("bound", toJson (toRawRat req.bound.toRat)),
    ("direction", toJson (if req.isUpperBound then "upper" else "lower")),
    ("config", Json.mkObj [
      ("max_iterations", toJson cfg.maxIterations),
      ("tolerance", toJson (toRawRat cfg.tolerance)),
      ("use_monotonicity", toJson cfg.useMonotonicity),
      ("taylor_depth", toJson cfg.taylorDepth)
    ])
  ]

def boundCertificateJson (req : CheckBoundRequest) (cfg : GlobalOptConfig)
    (checker verifier : String) : Json :=
  Json.mkObj [
    ("schema_version", toJson boundCertificateSchema),
    ("checker", toJson checker),
    ("verifier", toJson verifier),
    ("verification_route", toJson "compiled_checker"),
    ("payload", boundReplayPayloadJson req cfg)
  ]

def strictBoundCertificateJson (req : CheckStrictBoundRequest) (cfg : GlobalOptConfig)
    (certifiedBound : ℚ) (checker verifier : String) : Json :=
  Json.mkObj [
    ("schema_version", toJson strictBoundCertificateSchema),
    ("checker", toJson checker),
    ("verifier", toJson verifier),
    ("verification_route", toJson "compiled_checker"),
    ("payload", Json.mkObj [
      ("schema_version", toJson strictBoundReplayPayloadSchema),
      ("expression", exprToJson req.expr),
      ("box", toJson (req.box.map fun interval => toRawInterval interval.toInterval)),
      ("relation", toJson req.relation),
      ("target_bound", toJson (toRawRat req.bound.toRat)),
      ("certified_bound", toJson (toRawRat certifiedBound)),
      ("config", Json.mkObj [
        ("max_iterations", toJson cfg.maxIterations),
        ("tolerance", toJson (toRawRat cfg.tolerance)),
        ("use_monotonicity", toJson cfg.useMonotonicity),
        ("taylor_depth", toJson cfg.taylorDepth)
      ])
    ])
  ]

def adaptiveCertificateJson (req : VerifyAdaptiveRequest) (cfg : GlobalOptConfig)
    (result : GlobalResult) (checker verifier : String) : Json :=
  Json.mkObj [
    ("schema_version", toJson adaptiveCertificateSchema),
    ("checker", toJson checker),
    ("verifier", toJson verifier),
    ("verification_route", toJson "compiled_checker"),
    ("payload", Json.mkObj [
      ("schema_version", toJson adaptiveReplayPayloadSchema),
      ("expression", exprToJson req.expr),
      ("box", toJson (req.box.map fun interval => toRawInterval interval.toInterval)),
      ("bound", toJson (toRawRat req.bound.toRat)),
      ("direction", toJson (if req.isUpperBound then "upper" else "lower")),
      ("candidate_enclosure", Json.mkObj [
        ("lo", toJson (toRawRat result.bound.lo)),
        ("hi", toJson (toRawRat result.bound.hi))
      ]),
      ("config", Json.mkObj [
        ("max_iterations", toJson cfg.maxIterations),
        ("tolerance", toJson (toRawRat cfg.tolerance)),
        ("use_monotonicity", toJson cfg.useMonotonicity),
        ("taylor_depth", toJson cfg.taylorDepth)
      ])
    ])
  ]

def ratListJson (values : List ℚ) : Json :=
  toJson (values.map toRawRat)

def ratMatrixJson (values : List (List ℚ)) : Json :=
  Json.arr (values.map (fun row => ratListJson row)).toArray

def automaticKrawczykFailureJson : AutomaticKrawczykFailure → Json
  | .invalidDimension => Json.mkObj [("kind", toJson "invalid_dimension")]
  | .dimensionLimit actual limit => Json.mkObj [
      ("kind", toJson "dimension_limit"), ("actual", toJson actual), ("limit", toJson limit)]
  | .unsupportedAD => Json.mkObj [("kind", toJson "unsupported_expression")]
  | .singularPointJacobian attempt => Json.mkObj [
      ("kind", toJson "singular_point_jacobian"), ("attempt", toJson attempt)]
  | .centerEscaped attempt => Json.mkObj [
      ("kind", toJson "center_escaped"), ("attempt", toJson attempt)]
  | .stagnated attempt => Json.mkObj [
      ("kind", toJson "stagnated"), ("attempt", toJson attempt)]
  | .exhausted attempts => Json.mkObj [
      ("kind", toJson "exhausted"), ("attempts", toJson attempts)]

def krawczykCertificateJson (req : CheckUniqueSystemRootRequest)
    (center : List ℚ) (preconditioner : List (List ℚ)) : Json :=
  Json.mkObj [
    ("schema_version", toJson krawczykCertificateSchema),
    ("checker", toJson "LeanCert.Engine.krawczykCheck"),
    ("verifier", toJson "LeanCert.Validity.verify_unique_system_root"),
    ("verification_route", toJson "compiled_checker"),
    ("payload", Json.mkObj [
      ("schema_version", toJson krawczykReplayPayloadSchema),
      ("system", Json.arr (req.system.map exprToJson)),
      ("box", toJson (req.box.map fun interval => toRawInterval interval.toInterval)),
      ("center", ratListJson center),
      ("preconditioner", ratMatrixJson preconditioner),
      ("config", Json.mkObj [("taylor_depth", toJson req.taylorDepth)])
    ])
  ]

def eventualCertificateJson (req : CheckEventualBoundRequest) (cutoff : Nat) : Json :=
  Json.mkObj [
    ("schema_version", toJson eventualCertificateSchema),
    ("checker", toJson "LeanCert.Validity.checkReciprocalPowerUpper"),
    ("verifier", toJson "LeanCert.Validity.verify_reciprocal_power_upper"),
    ("verification_route", toJson "compiled_checker"),
    ("payload", Json.mkObj [
      ("schema_version", toJson eventualReplayPayloadSchema),
      ("coefficient", toJson (toRawRat req.coefficient.toRat)),
      ("bound", toJson (toRawRat req.bound.toRat)),
      ("exponent", toJson req.exponent),
      ("cutoff", toJson cutoff)
    ])
  ]

def scalarRootAuthority (claim : String) : String × String :=
  if claim == "exists" then
    ("LeanCert.Validity.RootFinding.checkSignChange",
      "LeanCert.Validity.RootFinding.verify_sign_change")
  else if claim == "unique" then
    ("LeanCert.Validity.RootFinding.checkNewtonContractsCore",
      "LeanCert.Validity.RootFinding.verify_unique_root_computable")
  else
    ("LeanCert.Validity.RootFinding.checkNoRoot",
      "LeanCert.Validity.RootFinding.verify_no_root")

def scalarRootCertificateJson (req : CheckScalarRootRequest) : Json :=
  let (checker, verifier) := scalarRootAuthority req.claim
  Json.mkObj [
    ("schema_version", toJson scalarRootCertificateSchema),
    ("checker", toJson checker),
    ("verifier", toJson verifier),
    ("verification_route", toJson "compiled_checker"),
    ("payload", Json.mkObj [
      ("schema_version", toJson scalarRootReplayPayloadSchema),
      ("expression", exprToJson req.expr),
      ("interval", toJson (toRawInterval req.interval.toInterval)),
      ("claim", toJson req.claim),
      ("config", Json.mkObj [("taylor_depth", toJson req.taylorDepth)])
    ])
  ]

def integralAuthority (relation : String) : String × String :=
  if relation == "eq" then
    ("LeanCert.Engine.QPoly.checkExactIntegral",
      "LeanCert.Engine.QPoly.integral_eq_of_check")
  else if relation == "upper" then
    ("LeanCert.Validity.Integration.checkIntegralPartitionUpperBound",
      "LeanCert.Validity.Integration.integral_partition_upper_of_check")
  else
    ("LeanCert.Validity.Integration.checkIntegralPartitionLowerBound",
      "LeanCert.Validity.Integration.integral_partition_lower_of_check")

def integralCertificateJson (req : CheckIntegralRequest)
    (partitions : Option Nat) : Json :=
  let (checker, verifier) := integralAuthority req.relation
  Json.mkObj [
    ("schema_version", toJson integralCertificateSchema),
    ("checker", toJson checker),
    ("verifier", toJson verifier),
    ("verification_route", toJson "compiled_checker"),
    ("payload", Json.mkObj [
      ("schema_version", toJson integralReplayPayloadSchema),
      ("expression", exprToJson req.expr),
      ("interval", toJson (toRawInterval req.interval.toInterval)),
      ("relation", toJson req.relation),
      ("bound", toJson (toRawRat req.bound.toRat)),
      ("partitions", partitions.map toJson |>.getD Json.null)
    ])
  ]

def integralSearchJson (source : String) (req : CheckIntegralRequest)
    (chosen : Option Nat) (attempts : Nat) (failure : Json := Json.null) : Json :=
  Json.mkObj [
    ("source", toJson source),
    ("start_partitions", if source == "automatic" then toJson req.startPartitions else Json.null),
    ("max_partitions", if source == "automatic" then toJson req.maxPartitions else Json.null),
    ("chosen_partitions", chosen.map toJson |>.getD Json.null),
    ("attempts", toJson attempts),
    ("failure", failure)
  ]

def integralFailureJson (kind detail : String) : Json :=
  Json.mkObj [("kind", toJson kind), ("detail", toJson detail)]

def integralOutcomeJson (req : CheckIntegralRequest) (status route backend : String)
    (enclosure search certificate : Json) : Json :=
  Json.mkObj [
    ("verified", toJson (status == "verified")),
    ("status", toJson status),
    ("relation", toJson req.relation),
    ("route", toJson route),
    ("backend", toJson backend),
    ("interval", toJson (toRawInterval req.interval.toInterval)),
    ("bound", toJson (toRawRat req.bound.toRat)),
    ("enclosure", enclosure),
    ("search", search),
    ("certificate", certificate)
  ]

def boundEnclosureJson (lo hi : ℚ) : Json :=
  Json.mkObj [
    ("lo", toJson (toRawRat lo)),
    ("hi", toJson (toRawRat hi))
  ]

/-- Handle interval evaluation request -/
def handleEvalInterval (req : EvalRequest) : Json :=
  -- Convert raw box to IntervalEnv
  let intervals := req.box.toList.map RawInterval.toInterval
  let env : IntervalEnv := fun i => intervals.getD i (IntervalRat.singleton 0)

  -- Run computation using evaluator with division support
  let cfg : EvalConfig := { taylorDepth := req.taylorDepth }
  let result := LeanCert.Internal.Rational.evalTotalCore req.expr env cfg

  -- Serialize result
  Json.mkObj [
    ("lo", toJson (toRawRat result.lo)),
    ("hi", toJson (toRawRat result.hi))
  ]

/-- Handle high-performance Dyadic interval evaluation request.

This evaluator uses Dyadic arithmetic (n * 2^e) instead of rationals,
preventing denominator explosion for deep expressions. It's 10-100x
faster for complex expressions like neural networks or nested Taylor series.

The result is returned both as Dyadic (exact) and as Rational (for
compatibility with the existing API). -/
def handleEvalIntervalDyadic (req : EvalDyadicRequest) : Json :=
  -- Convert raw box to Dyadic interval environment
  let intervals := req.box.toList.map RawInterval.toInterval
  let cfg := req.config.toDyadicConfig

  -- Create Dyadic environment from rational intervals
  let dyadicEnv : IntervalDyadicEnv := fun i =>
    let irat := intervals.getD i (IntervalRat.singleton 0)
    Core.IntervalDyadic.ofIntervalRat irat cfg.precision

  -- Run Dyadic evaluation
  let result := LeanCert.Internal.Dyadic.evalUnchecked req.expr dyadicEnv cfg

  -- Convert result to rational for compatibility
  let resultRat := result.toIntervalRat

  -- Return both Dyadic and Rational representations
  Json.mkObj [
    ("lo", toJson (toRawRat resultRat.lo)),
    ("hi", toJson (toRawRat resultRat.hi)),
    ("dyadic", Json.mkObj [
      ("lo", toJson (toRawDyadic result.lo)),
      ("hi", toJson (toRawDyadic result.hi))
    ])
  ]

/-- Handle Affine interval evaluation request.

This evaluator uses Affine Arithmetic to track correlations between variables,
solving the "dependency problem" in interval arithmetic. For example:
- Interval: x - x on [-1, 1] gives [-2, 2]
- Affine: x - x on [-1, 1] gives [0, 0] (exact!)

Affine arithmetic gives 50-90% tighter bounds for expressions with repeated
variables, which is common in neural network verification. -/
def handleEvalIntervalAffine (req : EvalAffineRequest) : Json :=
  -- Convert raw box to Affine environment
  let intervals := req.box.toList.map RawInterval.toInterval
  let cfg := req.config.toAffineConfig

  -- Create Affine environment from rational intervals
  let affineEnv := toAffineEnv intervals

  -- Run Affine evaluation
  let result := LeanCert.Internal.Affine.evalUnchecked req.expr affineEnv cfg

  -- Convert result to interval
  let resultInterval := result.toInterval

  Json.mkObj [
    ("lo", toJson (toRawRat resultInterval.lo)),
    ("hi", toJson (toRawRat resultInterval.hi)),
    ("affine", Json.mkObj [
      ("c0", toJson (toRawRat result.c0)),
      ("radius", toJson (toRawRat result.deviationBound))
    ])
  ]

/-- Handle global minimization request -/
def handleGlobalMin (req : OptimizeRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfig := {
    maxIterations := req.maxIters,
    tolerance := req.tolerance.toRat,
    useMonotonicity := req.useMonotonicity,
    taylorDepth := req.taylorDepth
  }

  let result := globalMinimizeCore req.expr box cfg

  -- Include bestBox for counterexample concretization
  let bestBoxJson := Json.arr (result.bound.bestBox.map (fun i => toJson (toRawInterval i))).toArray

  Json.mkObj [
    ("lo", toJson (toRawRat result.bound.lo)),
    ("hi", toJson (toRawRat result.bound.hi)),
    ("remainingBoxes", toJson result.remainingBoxes.length),
    ("bestBox", bestBoxJson)
  ]

/-- Handle global maximization request -/
def handleGlobalMax (req : OptimizeRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfig := {
    maxIterations := req.maxIters,
    tolerance := req.tolerance.toRat,
    useMonotonicity := req.useMonotonicity,
    taylorDepth := req.taylorDepth
  }

  let result := globalMaximizeCore req.expr box cfg

  -- Include bestBox for counterexample concretization
  let bestBoxJson := Json.arr (result.bound.bestBox.map (fun i => toJson (toRawInterval i))).toArray

  Json.mkObj [
    ("lo", toJson (toRawRat result.bound.lo)),
    ("hi", toJson (toRawRat result.bound.hi)),
    ("remainingBoxes", toJson result.remainingBoxes.length),
    ("bestBox", bestBoxJson)
  ]

/-- Handle global minimization request with Dyadic backend -/
def handleGlobalMinDyadic (req : OptimizeDyadicRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfigDyadic := {
    maxIterations := req.maxIters,
    tolerance := req.tolerance.toRat,
    useMonotonicity := req.useMonotonicity,
    taylorDepth := req.taylorDepth,
    precision := req.precision
  }

  let result := globalMinimizeDyadic req.expr box cfg

  let bestBoxJson := Json.arr (result.bound.bestBox.map (fun i => toJson (toRawInterval i))).toArray

  Json.mkObj [
    ("lo", toJson (toRawRat result.bound.lo)),
    ("hi", toJson (toRawRat result.bound.hi)),
    ("remainingBoxes", toJson result.remainingBoxes.length),
    ("bestBox", bestBoxJson)
  ]

/-- Handle global maximization request with Dyadic backend -/
def handleGlobalMaxDyadic (req : OptimizeDyadicRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfigDyadic := {
    maxIterations := req.maxIters,
    tolerance := req.tolerance.toRat,
    useMonotonicity := req.useMonotonicity,
    taylorDepth := req.taylorDepth,
    precision := req.precision
  }

  let result := globalMaximizeDyadic req.expr box cfg

  let bestBoxJson := Json.arr (result.bound.bestBox.map (fun i => toJson (toRawInterval i))).toArray

  Json.mkObj [
    ("lo", toJson (toRawRat result.bound.lo)),
    ("hi", toJson (toRawRat result.bound.hi)),
    ("remainingBoxes", toJson result.remainingBoxes.length),
    ("bestBox", bestBoxJson)
  ]

/-- Handle global minimization request with Affine backend -/
def handleGlobalMinAffine (req : OptimizeAffineRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfigAffine := {
    maxIterations := req.maxIters,
    tolerance := req.tolerance.toRat,
    useMonotonicity := req.useMonotonicity,
    taylorDepth := req.taylorDepth,
    maxNoiseSymbols := req.maxNoiseSymbols
  }

  let result := globalMinimizeAffine req.expr box cfg

  let bestBoxJson := Json.arr (result.bound.bestBox.map (fun i => toJson (toRawInterval i))).toArray

  Json.mkObj [
    ("lo", toJson (toRawRat result.bound.lo)),
    ("hi", toJson (toRawRat result.bound.hi)),
    ("remainingBoxes", toJson result.remainingBoxes.length),
    ("bestBox", bestBoxJson)
  ]

/-- Handle global maximization request with Affine backend -/
def handleGlobalMaxAffine (req : OptimizeAffineRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfigAffine := {
    maxIterations := req.maxIters,
    tolerance := req.tolerance.toRat,
    useMonotonicity := req.useMonotonicity,
    taylorDepth := req.taylorDepth,
    maxNoiseSymbols := req.maxNoiseSymbols
  }

  let result := globalMaximizeAffine req.expr box cfg

  let bestBoxJson := Json.arr (result.bound.bestBox.map (fun i => toJson (toRawInterval i))).toArray

  Json.mkObj [
    ("lo", toJson (toRawRat result.bound.lo)),
    ("hi", toJson (toRawRat result.bound.hi)),
    ("remainingBoxes", toJson result.remainingBoxes.length),
    ("bestBox", bestBoxJson)
  ]

/-- Handle bound checking request -/
def handleCheckBound (req : CheckBoundRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfig := {
    maxIterations := 1000
    tolerance := 1 / 1000
    useMonotonicity := true
    taylorDepth := req.taylorDepth
  }
  let env : IntervalEnv := box.toEnv
  let bound := req.bound.toRat
  let domainValid := checkDomainValid req.expr env { taylorDepth := req.taylorDepth }
  let supported := isGloballyOptimizable req.expr
  let result := if req.isUpperBound then
    globalMaximizeCore req.expr box cfg
  else
    globalMinimizeCore req.expr box cfg

  let inequality := if req.isUpperBound then
    decide (result.bound.hi ≤ bound)
  else
    decide (bound ≤ result.bound.lo)
  let verified := supported && domainValid && inequality
  let status := if !supported then "unsupported"
    else if !domainValid then "domain_obstruction"
    else if verified then "verified" else "inconclusive"
  let checker := if req.isUpperBound then
    "LeanCert.Validity.GlobalOpt.checkGlobalUpperBound"
  else
    "LeanCert.Validity.GlobalOpt.checkGlobalLowerBound"
  let verifier := if req.isUpperBound then
    "LeanCert.Validity.GlobalOpt.verify_global_upper_bound"
  else
    "LeanCert.Validity.GlobalOpt.verify_global_lower_bound"

  Json.mkObj [
    ("verified", toJson verified),
    ("computed_lo", toJson (toRawRat result.bound.lo)),
    ("computed_hi", toJson (toRawRat result.bound.hi)),
    ("status", toJson status),
    ("direction", toJson (if req.isUpperBound then "upper" else "lower")),
    ("enclosure", boundEnclosureJson result.bound.lo result.bound.hi),
    ("backend", toJson "rational_global_optimization"),
    ("certificate", if verified then
      boundCertificateJson req cfg checker verifier
      else Json.null)
  ]

/-- Check a strict global bound by retaining an interior non-strict bound.
    The fixed global checker proves `expr ≤ certified` or `certified ≤ expr`;
    exact rational comparison then supplies the strict margin to the target. -/
def handleCheckStrictBound (req : CheckStrictBoundRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfig := {
    maxIterations := 1000
    tolerance := 1 / 1000
    useMonotonicity := true
    taylorDepth := req.taylorDepth
  }
  let env : IntervalEnv := box.toEnv
  let target := req.bound.toRat
  let domainValid := checkDomainValid req.expr env { taylorDepth := req.taylorDepth }
  let supported := isGloballyOptimizable req.expr
  let isUpper := req.relation == "lt"
  let result := if isUpper then
    globalMaximizeCore req.expr box cfg
  else
    globalMinimizeCore req.expr box cfg
  let certified := if isUpper then result.bound.hi else result.bound.lo
  let margin := if isUpper then decide (certified < target) else decide (target < certified)
  let fixedChecked := if isUpper then
    LeanCert.Validity.GlobalOpt.checkGlobalUpperBound req.expr box certified cfg
  else
    LeanCert.Validity.GlobalOpt.checkGlobalLowerBound req.expr box certified cfg
  let verified := supported && domainValid && margin && fixedChecked
  let status := if !supported then "unsupported"
    else if !domainValid then "domain_obstruction"
    else if verified then "verified" else "inconclusive"
  let checker := if isUpper then
    "LeanCert.Validity.GlobalOpt.checkGlobalUpperBound"
  else
    "LeanCert.Validity.GlobalOpt.checkGlobalLowerBound"
  let verifier := if isUpper then
    "LeanCert.Validity.GlobalOpt.verify_global_upper_bound"
  else
    "LeanCert.Validity.GlobalOpt.verify_global_lower_bound"

  Json.mkObj [
    ("verified", toJson verified),
    ("status", toJson status),
    ("relation", toJson req.relation),
    ("target_bound", toJson (toRawRat target)),
    ("certified_bound", toJson (toRawRat certified)),
    ("enclosure", boundEnclosureJson result.bound.lo result.bound.hi),
    ("backend", toJson "rational_global_optimization"),
    ("certificate", if verified then
      strictBoundCertificateJson req cfg certified checker verifier
      else Json.null)
  ]

/-- Computable single-interval integration.
    Bounds the integral using interval arithmetic: width * f_bounds -/
def integrateIntervalCore1 (e : LExpr) (I : IntervalRat) (cfg : EvalConfig := {}) : IntervalRat :=
  let fBound := LeanCert.Internal.Rational.evalTotalCore e (fun _ => I) cfg
  IntervalRat.mul (IntervalRat.singleton I.width) fBound

/-- Computable uniform partition integration -/
def integrateIntervalCore (e : LExpr) (I : IntervalRat) (n : Nat) (cfg : EvalConfig := {}) : IntervalRat :=
  if n = 0 then IntervalRat.singleton 0
  else
    let width := (I.hi - I.lo) / n
    let parts := List.range n |>.map fun i =>
      let lo := I.lo + width * i
      let hi := I.lo + width * (i + 1)
      if h : lo ≤ hi then { lo := lo, hi := hi, le := h }
      else IntervalRat.singleton lo
    parts.foldl (fun acc J =>
      let fBound := LeanCert.Internal.Rational.evalTotalCore e (fun _ => J) cfg
      let contribution := IntervalRat.mul (IntervalRat.singleton J.width) fBound
      IntervalRat.add acc contribution
    ) (IntervalRat.singleton 0)

/-- Handle integration request -/
def handleIntegrate (req : IntegrateRequest) : Json :=
  let I := req.interval.toInterval
  let n := max 1 req.partitions
  let cfg : EvalConfig := { taylorDepth := req.taylorDepth }
  let result := integrateIntervalCore req.expr I n cfg

  Json.mkObj [
    ("lo", toJson (toRawRat result.lo)),
    ("hi", toJson (toRawRat result.hi))
  ]

/-- Check an exact integral equality or discover and retain one fixed uniform
    partition candidate for a one-sided integral bound. Search never appears
    in the certificate and cannot authorize success. -/
def handleCheckIntegral (req : CheckIntegralRequest) : Json :=
  let I := req.interval.toInterval
  let bound := req.bound.toRat
  if req.relation == "eq" then
    match QPoly.ofExpr req.expr with
    | none =>
        integralOutcomeJson req "unsupported" "exact_polynomial"
          "rational_exact_polynomial" Json.null
          (integralSearchJson "exact" req none 0
            (integralFailureJson "unsupported_expression"
              "exact integral equality requires a rational polynomial"))
          Json.null
    | some _ =>
        let checked := QPoly.checkExactIntegral req.expr I.lo I.hi bound
        let enclosure := if checked then
          toJson (toRawInterval (IntervalRat.singleton bound))
        else
          Json.null
        integralOutcomeJson req (if checked then "verified" else "candidate_rejected")
          "exact_polynomial" "rational_exact_polynomial" enclosure
          (integralSearchJson "exact" req none 0 (if checked then Json.null else
            integralFailureJson "incorrect_exact_value"
              "the exact polynomial checker rejected the claimed value"))
          (if checked then integralCertificateJson req none else Json.null)
  else if !req.expr.checkADSupported || !req.expr.usesOnlyVar0 then
    integralOutcomeJson req "unsupported" "checked_partitions"
      "rational_checked_partitions" Json.null
      (integralSearchJson "automatic" req none 0
        (integralFailureJson "unsupported_expression"
          "checked integral bounds currently require the globally continuous AD fragment"))
      Json.null
  else
    let search := if req.relation == "upper" then
      Validity.Integration.searchPartitionUpperCandidate req.expr I
        req.startPartitions req.maxPartitions bound
    else
      Validity.Integration.searchPartitionLowerCandidate req.expr I
        req.startPartitions req.maxPartitions bound
    match search with
    | .success chosen enclosure attempts =>
        let checked := if req.relation == "upper" then
          Validity.Integration.checkIntegralPartitionUpperBound req.expr I chosen bound
        else
          Validity.Integration.checkIntegralPartitionLowerBound req.expr I chosen bound
        integralOutcomeJson req (if checked then "verified" else "candidate_rejected")
          "checked_partitions" "rational_checked_partitions"
          (toJson (toRawInterval enclosure))
          (integralSearchJson "automatic" req (some chosen) attempts
            (if checked then Json.null else integralFailureJson "rejected_partition"
              "the fixed partition checker rejected the discovered candidate"))
          (if checked then integralCertificateJson req (some chosen) else Json.null)
    | .exhausted lastPartitions lastEnclosure attempts =>
        integralOutcomeJson req "inconclusive" "checked_partitions"
          "rational_checked_partitions"
          (lastEnclosure.map (fun enclosure => toJson (toRawInterval enclosure))
            |>.getD Json.null)
          (integralSearchJson "automatic" req lastPartitions attempts
            (integralFailureJson "search_exhausted"
              "partition discovery exhausted its configured maximum"))
          Json.null
    | .domainObstruction partitions attempts =>
        integralOutcomeJson req "domain_obstruction" "checked_partitions"
          "rational_checked_partitions" Json.null
          (integralSearchJson "automatic" req (some partitions) attempts
            (integralFailureJson "domain_obstruction"
              "a partition cell could not be evaluated on the expression domain"))
          Json.null
    | .invalidStart =>
        integralOutcomeJson req "unsupported" "checked_partitions"
          "rational_checked_partitions" Json.null
          (integralSearchJson "automatic" req none 0
            (integralFailureJson "invalid_configuration"
              "partition discovery requires a positive starting count"))
          Json.null

/-! ## Root Finding (Computable) -/

/-- Root status for computable root finding -/
inductive RootStatusCore where
  | noRoot     -- Interval excludes zero
  | hasRoot    -- Sign change detected (IVT applies)
  | unknown    -- Cannot determine
  deriving Repr, DecidableEq

instance : ToJson RootStatusCore where
  toJson s := match s with
    | .noRoot => "noRoot"
    | .hasRoot => "hasRoot"
    | .unknown => "unknown"

/-- Check if interval excludes zero (computable) -/
def excludesZeroCore (I : IntervalRat) : Bool :=
  I.hi < 0 || 0 < I.lo

/-- Check if function has opposite signs at endpoints (computable) -/
def signChangeCore (e : LExpr) (I : IntervalRat) (cfg : EvalConfig) : Bool :=
  let flo := LeanCert.Internal.Rational.evalTotalCore e
    (fun _ => IntervalRat.singleton I.lo) cfg
  let fhi := LeanCert.Internal.Rational.evalTotalCore e
    (fun _ => IntervalRat.singleton I.hi) cfg
  (flo.hi < 0 && 0 < fhi.lo) || (fhi.hi < 0 && 0 < flo.lo)

/-- Determine root status (computable) -/
def checkRootStatusCore (e : LExpr) (I : IntervalRat) (cfg : EvalConfig) : RootStatusCore :=
  let fI := LeanCert.Internal.Rational.evalTotalCore e (fun _ => I) cfg
  if excludesZeroCore fI then
    RootStatusCore.noRoot
  else if signChangeCore e I cfg then
    RootStatusCore.hasRoot
  else
    RootStatusCore.unknown

/-- Result of computable bisection root finding -/
structure BisectionResultCore where
  intervals : List (IntervalRat × RootStatusCore)
  iterations : Nat

/-- Computable bisection root finding worker -/
def bisectRootGoCore (e : LExpr) (tol : ℚ) (maxIter : Nat)
    (work : List (IntervalRat × RootStatusCore)) (iter : Nat)
    (done : List (IntervalRat × RootStatusCore)) (cfg : EvalConfig) : BisectionResultCore :=
  match iter, work with
  | 0, _ =>
    { intervals := done ++ work
      iterations := maxIter }
  | _, [] =>
    { intervals := done
      iterations := maxIter - iter }
  | n + 1, (J, _) :: rest =>
    let status := checkRootStatusCore e J cfg
    match status with
    | RootStatusCore.noRoot =>
      -- Discard this interval
      bisectRootGoCore e tol maxIter rest n done cfg
    | RootStatusCore.hasRoot =>
      if J.width ≤ tol then
        bisectRootGoCore e tol maxIter rest n ((J, RootStatusCore.hasRoot) :: done) cfg
      else
        let (J₁, J₂) := J.bisect
        bisectRootGoCore e tol maxIter ((J₁, .unknown) :: (J₂, .unknown) :: rest) n done cfg
    | RootStatusCore.unknown =>
      if J.width ≤ tol then
        bisectRootGoCore e tol maxIter rest n ((J, RootStatusCore.unknown) :: done) cfg
      else
        let (J₁, J₂) := J.bisect
        bisectRootGoCore e tol maxIter ((J₁, .unknown) :: (J₂, .unknown) :: rest) n done cfg

/-- Computable bisection root finding -/
def bisectRootCore (e : LExpr) (I : IntervalRat) (maxIter : Nat) (tol : ℚ) (cfg : EvalConfig) : BisectionResultCore :=
  bisectRootGoCore e tol maxIter [(I, RootStatusCore.unknown)] maxIter [] cfg

/-- Handle root finding request -/
def handleFindRoots (req : FindRootsRequest) : Json :=
  let I := req.interval.toInterval
  let cfg : EvalConfig := { taylorDepth := req.taylorDepth }
  let result := bisectRootCore req.expr I req.maxIter req.tolerance.toRat cfg

  let roots := result.intervals.map fun (J, status) =>
    Json.mkObj [
      ("lo", toJson (toRawRat J.lo)),
      ("hi", toJson (toRawRat J.hi)),
      ("status", toJson status)
    ]

  Json.mkObj [
    ("roots", Json.arr roots.toArray),
    ("iterations", toJson result.iterations)
  ]

/-- Handle unique root finding request via Newton contraction.

    Checks if Newton contraction holds, indicating a unique root exists.
    This is a stronger result than bisection (which only proves existence). -/
def handleFindUniqueRoot (req : FindUniqueRootRequest) : Json :=
  let I := req.interval.toInterval
  let cfg : EvalConfig := { taylorDepth := req.taylorDepth }

  -- Check if Newton contraction holds (computable version)
  let contracts := Validity.RootFinding.checkNewtonContractsCore req.expr I cfg

  -- Also get the Newton step result for the refined interval
  let newtonResult := Validity.RootFinding.newtonStepCore req.expr I cfg

  match newtonResult with
  | none =>
    -- Newton step failed (derivative contains 0 or other issue)
    Json.mkObj [
      ("unique", toJson false),
      ("reason", "newton_step_failed"),
      ("interval", Json.mkObj [
        ("lo", toJson (toRawRat I.lo)),
        ("hi", toJson (toRawRat I.hi))
      ])
    ]
  | some N =>
    if contracts then
      -- Contraction! Unique root exists in N (and hence in I)
      Json.mkObj [
        ("unique", toJson true),
        ("reason", "newton_contraction"),
        ("interval", Json.mkObj [
          ("lo", toJson (toRawRat N.lo)),
          ("hi", toJson (toRawRat N.hi))
        ])
      ]
    else
      -- Newton step succeeded but didn't contract
      -- Still may have a root, but uniqueness not proven
      Json.mkObj [
        ("unique", toJson false),
        ("reason", "no_contraction"),
        ("interval", Json.mkObj [
          ("lo", toJson (toRawRat N.lo)),
          ("hi", toJson (toRawRat N.hi))
        ])
      ]

/-- Check a fixed scalar interval using one of LeanCert's published root
    checkers. Successful responses retain precisely the checker input; no
    bridge-side heuristic is part of the proof authority. -/
def handleCheckScalarRoot (req : CheckScalarRootRequest) : Json :=
  let I := req.interval.toInterval
  let cfg : EvalConfig := { taylorDepth := req.taylorDepth }
  let supported := if req.claim == "unique" || req.claim == "exists" then
    req.expr.checkADSupported && req.expr.usesOnlyVar0
  else
    req.expr.checkSupportedCore
  let checked := if !supported then false
    else if req.claim == "exists" then
      Validity.RootFinding.checkSignChange req.expr I cfg
    else if req.claim == "unique" then
      Validity.RootFinding.checkNewtonContractsCore req.expr I cfg
    else
      Validity.RootFinding.checkNoRoot req.expr I cfg
  Json.mkObj [
    ("verified", toJson checked),
    ("status", toJson (if !supported then "unsupported"
      else if checked then "verified" else "candidate_rejected")),
    ("claim", toJson req.claim),
    ("backend", toJson "rational_scalar_root"),
    ("interval", toJson (toRawInterval I)),
    ("certificate", if checked then scalarRootCertificateJson req else Json.null)
  ]

/-- Generate or accept an exact rational Krawczyk candidate, then independently
    run the fixed Boolean checker which is the sole authority for success. -/
def handleCheckUniqueSystemRoot (req : CheckUniqueSystemRootRequest) : Json :=
  let n := req.system.size
  let system : Fin n → LExpr := fun i => req.system[i.val]!
  let box : Fin n → IntervalRat := fun i => req.box[i.val]!.toInterval
  let cfg : EvalConfig := { taylorDepth := req.taylorDepth }
  let search : AutomaticKrawczykConfig := {
    maxIterations := req.maxIterations
    maxDimension := req.maxDimension
    precisionBits := req.precisionBits
  }
  let report := match req.candidate with
    | none => generateAutomaticKrawczyk system box cfg search
    | some candidate =>
        let center := candidate.center.toList.map RawRat.toRat
        let preconditioner := candidate.preconditioner.toList.map fun (row : Array RawRat) =>
          row.toList.map RawRat.toRat
        let cert := KrawczykCert.ofLists n center preconditioner
        let checked := krawczykCheck system box cert cfg
        {
          dimension := n
          attempts := 1
          center
          preconditioner
          failure := if checked then none else some (.exhausted 1)
        }
  let checked := if report.succeeded then
    let cert := KrawczykCert.ofLists n report.center report.preconditioner
    krawczykCheck system box cert cfg
  else false
  let status := if checked then "verified" else match report.failure with
    | some .unsupportedAD => "unsupported"
    | some .invalidDimension | some (.dimensionLimit ..) => "unsupported"
    | some (.singularPointJacobian ..) | some (.centerEscaped ..) |
        some (.stagnated ..) | some (.exhausted ..) => "candidate_rejected"
    | none => "candidate_rejected"
  Json.mkObj [
    ("verified", toJson checked),
    ("status", toJson status),
    ("backend", toJson "rational_krawczyk"),
    ("root_box", toJson (req.box.map fun interval => toRawInterval interval.toInterval)),
    ("search", Json.mkObj [
      ("source", toJson (if req.candidate.isSome then "provided" else "automatic")),
      ("attempts", toJson report.attempts),
      ("refinements", toJson report.refinements),
      ("contraction_bound", toJson (toRawRat report.contractionBound)),
      ("failure", report.failure.map automaticKrawczykFailureJson |>.getD Json.null)
    ]),
    ("certificate", if checked then
      krawczykCertificateJson req report.center report.preconditioner
      else Json.null)
  ]

def eventualSearchJson (statistics : EventualSearchStatistics) : Json :=
  Json.mkObj [
    ("source", toJson "automatic"),
    ("checks", toJson statistics.checks),
    ("configured_limit", toJson statistics.configuredLimit),
    ("exponential_steps", toJson statistics.exponentialSteps),
    ("refinement_steps", toJson statistics.refinementSteps),
    ("lower_bracket", toJson statistics.lowerBracket),
    ("upper_bracket", toJson statistics.upperBracket),
    ("refinement_complete", toJson statistics.refinementComplete)
  ]

def fixedEventualSearchJson : Json :=
  Json.mkObj [("source", toJson "provided")]

def requestedEventualSearchJson (cutoff : Option Nat) : Json :=
  Json.mkObj [("source", toJson (if cutoff.isSome then "provided" else "automatic"))]

def eventualFailureJson (kind detail : String) : Json :=
  Json.mkObj [("kind", toJson kind), ("detail", toJson detail)]

/-- Check a supplied cutoff or discover one using LeanCert's deterministic,
    untrusted search. Every successful candidate is replayed through the exact
    reciprocal-power checker before a certificate is emitted. -/
def handleCheckEventualBound (req : CheckEventualBoundRequest) : Json :=
  let q := req.coefficient.toRat
  let bound := req.bound.toRat
  let checked (cutoff : Nat) :=
    LeanCert.Validity.checkReciprocalPowerUpper q bound req.exponent cutoff
  let outcome (status : String) (cutoff : Option Nat) (search failure certificate : Json) :=
    Json.mkObj [
      ("verified", toJson (status == "verified")),
      ("status", toJson status),
      ("backend", toJson "rational_reciprocal_power"),
      ("cutoff", cutoff.map toJson |>.getD Json.null),
      ("search", search),
      ("failure", failure),
      ("certificate", certificate)
    ]
  if q < 0 then
    outcome "unsupported" req.cutoff (requestedEventualSearchJson req.cutoff)
      (eventualFailureJson "negative_coefficient"
        "the supported tail language requires a nonnegative coefficient") Json.null
  else if req.exponent = 0 then
    outcome "unsupported" req.cutoff (requestedEventualSearchJson req.cutoff)
      (eventualFailureJson "nonpositive_exponent"
        "the supported tail language requires a positive exponent") Json.null
  else match req.cutoff with
    | some cutoff =>
        if checked cutoff then
          outcome "verified" (some cutoff) fixedEventualSearchJson Json.null
            (eventualCertificateJson req cutoff)
        else
          outcome "candidate_rejected" (some cutoff) fixedEventualSearchJson
            (eventualFailureJson "rejected_cutoff"
              s!"the exact checker rejected cutoff {cutoff}") Json.null
    | none =>
        if bound < 0 || (0 < q && bound = 0) then
          outcome "candidate_rejected" none
            (Json.mkObj [("source", toJson "automatic")])
            (eventualFailureJson "impossible_bound"
              "a nonnegative reciprocal-power tail cannot satisfy this upper bound") Json.null
        else match discoverEventualCutoff q bound req.exponent req.maxChecks with
          | .ok statistics =>
              if checked statistics.cutoff then
                outcome "verified" (some statistics.cutoff)
                  (eventualSearchJson statistics) Json.null
                  (eventualCertificateJson req statistics.cutoff)
              else
                outcome "candidate_rejected" (some statistics.cutoff)
                  (eventualSearchJson statistics)
                  (eventualFailureJson "rejected_discovered_cutoff"
                    "the exact checker rejected the discovered cutoff") Json.null
          | .error (checks, lastCutoff) =>
              outcome "inconclusive" none
                (Json.mkObj [
                  ("source", toJson "automatic"),
                  ("checks", toJson checks),
                  ("configured_limit", toJson req.maxChecks),
                  ("last_cutoff", toJson lastCutoff)
                ])
                (eventualFailureJson "search_exhausted"
                  "cutoff discovery exhausted its configured check budget") Json.null

/-- Handle adaptive verification request using optimization -/
def handleVerifyAdaptive (req : VerifyAdaptiveRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : GlobalOptConfig := {
    maxIterations := req.maxIters,
    tolerance := req.tolerance.toRat,
    useMonotonicity := true,
    taylorDepth := req.taylorDepth
  }
  let bound := req.bound.toRat
  let env : IntervalEnv := fun i => box.getD i (IntervalRat.singleton 0)
  let domainValid := checkDomainValid req.expr env { taylorDepth := req.taylorDepth }
  let supported := isGloballyOptimizable req.expr
  let checker := if req.isUpperBound then
    "LeanCert.Engine.Optimization.globalMaximizeRationalChecked"
  else
    "LeanCert.Engine.Optimization.globalMinimizeRationalChecked"
  let verifier := if req.isUpperBound then
    "LeanCert.Engine.Optimization.globalMaximizeRationalChecked_hi_correct"
  else
    "LeanCert.Engine.Optimization.globalMinimizeRationalChecked_lo_correct"
  if !supported then
    Json.mkObj [
      ("verified", toJson false),
      ("status", toJson "unsupported"),
      ("direction", toJson (if req.isUpperBound then "upper" else "lower")),
      ("backend", toJson "rational_checked_global_optimization"),
      ("certificate", Json.null)
    ]
  else if !domainValid then
    Json.mkObj [
      ("verified", toJson false),
      ("status", toJson "domain_obstruction"),
      ("direction", toJson (if req.isUpperBound then "upper" else "lower")),
      ("backend", toJson "rational_checked_global_optimization"),
      ("certificate", Json.null)
    ]
  else
    let checked := if req.isUpperBound then
      globalMaximizeRationalChecked req.expr box cfg
    else
      globalMinimizeRationalChecked req.expr box cfg
    match checked with
    | .error failure =>
      Json.mkObj [
        ("verified", toJson false),
        ("status", toJson "inconclusive"),
        ("direction", toJson (if req.isUpperBound then "upper" else "lower")),
        ("backend", toJson "rational_checked_global_optimization"),
        ("failure", toJson (reprStr failure)),
        ("certificate", Json.null)
      ]
    | .ok result =>
      let inequality := if req.isUpperBound then
        decide (result.bound.hi ≤ bound)
      else
        decide (bound ≤ result.bound.lo)
      let gap := if req.isUpperBound then bound - result.bound.hi
        else result.bound.lo - bound
      Json.mkObj [
        ("verified", toJson inequality),
        ("minValue", toJson (toRawRat gap)),
        ("remainingBoxes", toJson result.remainingBoxes.length),
        ("status", toJson (if inequality then "verified" else "inconclusive")),
        ("direction", toJson (if req.isUpperBound then "upper" else "lower")),
        ("enclosure", boundEnclosureJson result.bound.lo result.bound.hi),
        ("backend", toJson "rational_checked_global_optimization"),
        ("certificate", if inequality then
          adaptiveCertificateJson req cfg result checker verifier
          else Json.null)
      ]

/-- Handle neural network forward interval propagation request.

This handler takes a sequential neural network (list of layers) and an input
interval vector, then propagates the intervals through the network using
verified interval arithmetic.

Each layer performs: y = ReLU(W·x + b) (with ReLU for all but last layer)

Returns: Array of output intervals -/
def handleForwardInterval (req : ForwardIntervalRequest) : Json :=
  -- Convert raw layers to ML.Layer
  let layers : List LeanCert.ML.Layer := req.layers.toList.map RawLayer.toLayer

  -- Convert raw input intervals to IntervalVector (using Dyadic)
  let input : LeanCert.Engine.IntervalVector :=
    req.input.toList.map (fun ri =>
      let irat := ri.toInterval
      Core.IntervalDyadic.ofIntervalRat irat req.precision)

  -- Build SequentialNet and run forward propagation
  let net : LeanCert.ML.Distillation.SequentialNet := { layers := layers }
  let output := LeanCert.ML.Distillation.SequentialNet.forwardInterval net input req.precision

  -- Serialize output intervals
  let outputJson := output.map (fun I =>
    Json.mkObj [
      ("lo", toJson (toRawRat I.lo.toRat)),
      ("hi", toJson (toRawRat I.hi.toRat))
    ])

  Json.mkObj [
    ("output", Json.arr outputJson.toArray),
    ("numLayers", toJson layers.length),
    ("outputDim", toJson output.length)
  ]

/-- Handle derivative interval request.

Computes bounds on all partial derivatives (the gradient) over a box.
This is used for computing Lipschitz constants: L = max_i sup_x |∂f/∂xᵢ(x)|.

Returns: Array of intervals, one per variable, each containing ∂f/∂xᵢ for all x ∈ box.
Also returns the Lipschitz bound L = max(|lo|, |hi|) over all partial derivatives. -/
def handleDerivInterval (req : DerivIntervalRequest) : Json :=
  let box : Box := req.box.toList.map RawInterval.toInterval
  let cfg : EvalConfig := { taylorDepth := req.taylorDepth }

  -- Compute gradient interval using computable AD
  let gradients := Optimization.gradientIntervalCore req.expr box cfg

  -- Compute Lipschitz bound: max of absolute values of all partial derivative bounds
  let lipschitzBound := gradients.foldl (fun acc I =>
    max acc (max (abs I.lo) (abs I.hi))) (0 : ℚ)

  -- Serialize gradient intervals
  let gradientsJson := gradients.map (fun I =>
    Json.mkObj [
      ("lo", toJson (toRawRat I.lo)),
      ("hi", toJson (toRawRat I.hi))
    ])

  Json.mkObj [
    ("gradients", Json.arr gradientsJson.toArray),
    ("lipschitz_bound", toJson (toRawRat lipschitzBound)),
    ("num_vars", toJson gradients.length)
  ]

private def realRatExpr (value : ℚ) : Lean.MetaM Lean.Expr :=
  Lean.Meta.mkAppOptM ``Rat.cast #[Lean.mkConst ``Real, none, Lean.toExpr value]

private partial def registeredExprToLean (runtime : EnclosureRuntime)
    (variableExpr : Lean.Expr) : RegisteredExpr → Lean.MetaM Lean.Expr
  | .rational value => realRatExpr value.toRat
  | .variable => pure variableExpr
  | .neg value => do
      let value ← registeredExprToLean runtime variableExpr value
      Lean.Meta.mkAppM ``Neg.neg #[value]
  | .add left right => do
      let left ← registeredExprToLean runtime variableExpr left
      let right ← registeredExprToLean runtime variableExpr right
      Lean.Meta.mkAppM ``HAdd.hAdd #[left, right]
  | .sub left right => do
      let left ← registeredExprToLean runtime variableExpr left
      let right ← registeredExprToLean runtime variableExpr right
      Lean.Meta.mkAppM ``HSub.hSub #[left, right]
  | .mul left right => do
      let left ← registeredExprToLean runtime variableExpr left
      let right ← registeredExprToLean runtime variableExpr right
      Lean.Meta.mkAppM ``HMul.hMul #[left, right]
  | .div left right => do
      let left ← registeredExprToLean runtime variableExpr left
      let right ← registeredExprToLean runtime variableExpr right
      Lean.Meta.mkAppM ``HDiv.hDiv #[left, right]
  | .pow base exponent => do
      let base ← registeredExprToLean runtime variableExpr base
      Lean.Meta.mkAppM ``HPow.hPow #[base, Lean.toExpr exponent]
  | .registered functionName argument => do
      let functionName := functionName.toName
      unless runtime.rules.any fun rule => rule.functionName == functionName do
        throwError "registered function `{functionName}` is not allowed by the startup profile"
      Lean.Meta.mkAppM functionName #[← registeredExprToLean runtime variableExpr argument]
  | .builtin name argument => do
      let argument ← registeredExprToLean runtime variableExpr argument
      match name with
      | "sin" => Lean.Meta.mkAppM ``Real.sin #[argument]
      | "cos" => Lean.Meta.mkAppM ``Real.cos #[argument]
      | "exp" => Lean.Meta.mkAppM ``Real.exp #[argument]
      | "log" => Lean.Meta.mkAppM ``Real.log #[argument]
      | "sqrt" => Lean.Meta.mkAppM ``Real.sqrt #[argument]
      | "inv" => Lean.Meta.mkAppM ``Inv.inv #[argument]
      | "atan" => Lean.Meta.mkAppM ``Real.arctan #[argument]
      | "arsinh" => Lean.Meta.mkAppM ``Real.arsinh #[argument]
      | "atanh" => Lean.Meta.mkAppM ``Real.atanh #[argument]
      | "sinc" => Lean.Meta.mkAppM ``Real.sinc #[argument]
      | "erf" => Lean.Meta.mkAppM ``Real.erf #[argument]
      | "abs" => Lean.Meta.mkAppM ``abs #[argument]
      | "sinh" => Lean.Meta.mkAppM ``Real.sinh #[argument]
      | "cosh" => Lean.Meta.mkAppM ``Real.cosh #[argument]
      | "tanh" => Lean.Meta.mkAppM ``Real.tanh #[argument]
      | other => throwError "unsupported registered-expression builtin `{other}`"

private def registeredProposition (runtime : EnclosureRuntime)
    (request : CheckRegisteredEnclosureRequest) : Lean.MetaM Lean.Expr := do
  Lean.Meta.withLocalDeclD `x (Lean.mkConst ``Real) fun x => do
    let expression ← registeredExprToLean runtime x request.expression
    let bound ← realRatExpr request.bound.toRat
    let comparison ← match request.relation with
      | "le" => Lean.Meta.mkAppM ``LE.le #[expression, bound]
      | "lt" => Lean.Meta.mkAppM ``LT.lt #[expression, bound]
      | "ge" => Lean.Meta.mkAppM ``LE.le #[bound, expression]
      | "gt" => Lean.Meta.mkAppM ``LT.lt #[bound, expression]
      | _ => throwError "invalid registered enclosure relation"
    let loRat := request.domain.lo.toRat
    let hiRat := request.domain.hi.toRat
    let orderedType ← Lean.Meta.mkAppM ``LE.le #[Lean.toExpr loRat, Lean.toExpr hiRat]
    let ordered ← Lean.Meta.mkDecideProof orderedType
    let interval ← Lean.Meta.mkAppM ``IntervalRat.mk
      #[Lean.toExpr loRat, Lean.toExpr hiRat, ordered]
    let membership ← Lean.Meta.mkAppM ``Membership.mem #[interval, x]
    let implication ← Lean.mkArrow membership comparison
    Lean.Meta.mkForallFVars #[x] implication

private def ruleToJson (rule : LeanCert.Tactic.Extension.UnaryEnclosureRule) : Json :=
  Json.mkObj [
    ("function", toJson rule.functionName.toString),
    ("candidate", toJson rule.candidateName.toString),
    ("checker", toJson rule.checkerName.toString),
    ("theorem", toJson rule.theoremName.toString),
    ("priority", toJson rule.rulePriority)
  ]

private def enclosureEntryToJson
    (entry : LeanCert.Tactic.Extension.RegisteredEnclosureCertificateEntry) : Json :=
  Json.mkObj [
    ("rule", ruleToJson entry.rule),
    ("request", Json.mkObj [
      ("input", toJson (toRawInterval entry.request.input)),
      ("precision", toJson entry.request.precision),
      ("taylor_depth", toJson entry.request.taylorDepth)
    ]),
    ("output", toJson (toRawInterval entry.output))
  ]

private partial def enclosureTreeToJson :
    LeanCert.Tactic.Extension.RegisteredEnclosureCertificateTree → Json
  | .leaf input output entries compositionSteps => Json.mkObj [
      ("kind", toJson "leaf"),
      ("input", toJson (toRawInterval input)),
      ("output", toJson (toRawInterval output)),
      ("entries", Json.arr (entries.map enclosureEntryToJson)),
      ("composition_steps", toJson compositionSteps)
    ]
  | .bisect input left right => Json.mkObj [
      ("kind", toJson "bisect"),
      ("input", toJson (toRawInterval input)),
      ("left", enclosureTreeToJson left),
      ("right", enclosureTreeToJson right)
    ]

private def enclosureCertificateToJson (runtime : EnclosureRuntime)
    (certificate : LeanCert.Tactic.Extension.RegisteredEnclosureCertificate) : Json :=
  Json.mkObj [
    ("schema", toJson registeredEnclosureCertificateSchema),
    ("replay_payload_schema", toJson registeredEnclosureReplayPayloadSchema),
    ("profile", profileToJson runtime),
    ("precision", toJson certificate.precision),
    ("taylor_depth", toJson certificate.taylorDepth),
    ("configured_max_depth", toJson certificate.configuredMaxDepth),
    ("tree", enclosureTreeToJson certificate.tree)
  ]

private def registeredFailureToJson
    (failure : LeanCert.Tactic.Extension.RegisteredEnclosureFailure) : Json :=
  let (status, detail) := match failure with
    | .notApplicable => ("unsupported", "claim is not a supported registered enclosure bound")
    | .unsupported expression detail => ("unsupported", s!"{detail}: {expression}")
    | .domainObstruction operation detail => ("domain_obstruction", s!"{operation}: {detail}")
    | .inconclusive detail _ => ("inconclusive", detail)
    | .rejected _ _ detail => ("candidate_rejected", detail)
    | .exhausted maxDepth boxes deepest leaves _ detail =>
        ("inconclusive", s!"subdivision exhausted at depth {maxDepth} after {boxes} boxes (deepest {deepest}, leaves {leaves}): {detail}")
    | .verificationFailure detail => ("verification_failure", detail)
  Json.mkObj [("status", toJson status), ("detail", toJson detail)]

/-- Structured infrastructure error used by Bridge Contract 2.0. -/
def protocolError (code message : String) : Json :=
  Json.mkObj [("error", Json.mkObj [
    ("code", toJson code),
    ("message", toJson message)
  ])]

unsafe def handleCheckRegisteredEnclosure (runtime : EnclosureRuntime)
    (request : CheckRegisteredEnclosureRequest) : IO Json := do
  let action : Lean.MetaM (Except LeanCert.Tactic.Extension.RegisteredEnclosureFailure
      (LeanCert.Tactic.Extension.RegisteredEnclosureOutcome × Lean.Expr)) := do
    let proposition ← registeredProposition runtime request
    LeanCert.Tactic.Extension.discoverRegisteredEnclosureBoundMeta proposition
      request.precision request.taylorDepth request.maxDepth
  let coreContext : Lean.Core.Context := {
    fileName := "<leancert-bridge-enclosure>"
    fileMap := Lean.FileMap.ofString ""
  }
  let coreState : Lean.Core.State := { env := runtime.environment }
  let (result, _, _) ← action.toIO coreContext coreState
  match result with
  | .error failure => return registeredFailureToJson failure
  | .ok (outcome, _) =>
      return Json.mkObj [
        ("status", toJson "verified"),
        ("enclosure", toJson (toRawInterval outcome.enclosure)),
        ("registered_checks", toJson outcome.observations.size),
        ("composition_steps", toJson outcome.compositionSteps),
        ("certificate", enclosureCertificateToJson runtime outcome.certificate)
      ]

unsafe def dispatchCheckRegisteredEnclosure (runtime : Option EnclosureRuntime)
    (args : Json) : IO Json := do
  let some selectedRuntime := runtime
    | return protocolError "profile_required"
        "check_registered_enclosure requires --enclosure-profile at bridge startup"
  let request ← match fromJson? (α := CheckRegisteredEnclosureRequest) args with
    | .ok request => pure request
    | .error parseError =>
        let detail := s!"Invalid check_registered_enclosure params: {parseError}"
        return protocolError "invalid_params" detail
  try
    return Json.mkObj [
      ("result", ← handleCheckRegisteredEnclosure selectedRuntime request)]
  catch error =>
    return protocolError "enclosure_execution_error" error.toString

unsafe def handleReplayRegisteredEnclosure (runtime : EnclosureRuntime)
    (request : ReplayRegisteredEnclosureRequest) : IO Json := do
  unless request.retained.profileName == runtime.profile.name &&
      request.retained.leanCertRevision == runtime.profile.leanCertRevision &&
      request.retained.environmentDigest == runtime.profile.environmentDigest do
    return Json.mkObj [
      ("status", toJson "verification_failure"),
      ("detail", toJson "certificate profile identity does not match the loaded environment")]
  let action : Lean.MetaM (Except LeanCert.Tactic.Extension.RegisteredEnclosureFailure
      (LeanCert.Tactic.Extension.RegisteredEnclosureOutcome × Lean.Expr)) := do
    let proposition ← registeredProposition runtime request.claim
    LeanCert.Tactic.Extension.replayRegisteredEnclosureBoundMeta proposition
      request.retained.certificate
  let coreContext : Lean.Core.Context := {
    fileName := "<leancert-bridge-enclosure-replay>"
    fileMap := Lean.FileMap.ofString ""
  }
  let coreState : Lean.Core.State := { env := runtime.environment }
  let (result, _, _) ← action.toIO coreContext coreState
  match result with
  | .error failure => return registeredFailureToJson failure
  | .ok (outcome, _) => return Json.mkObj [
      ("status", toJson "verified"),
      ("enclosure", toJson (toRawInterval outcome.enclosure)),
      ("registered_checks", toJson outcome.observations.size),
      ("composition_steps", toJson outcome.compositionSteps),
      ("replayed", toJson true),
      ("certificate", enclosureCertificateToJson runtime outcome.certificate)
    ]

unsafe def dispatchReplayRegisteredEnclosure (runtime : Option EnclosureRuntime)
    (args : Json) : IO Json := do
  let some selectedRuntime := runtime
    | return protocolError "profile_required"
        "replay_registered_enclosure requires --enclosure-profile at bridge startup"
  let request ← match fromJson? (α := ReplayRegisteredEnclosureRequest) args with
    | .ok request => pure request
    | .error parseError =>
        let detail := s!"Invalid replay_registered_enclosure params: {parseError}"
        return protocolError "invalid_params" detail
  try
    return Json.mkObj [
      ("result", ← handleReplayRegisteredEnclosure selectedRuntime request)]
  catch error =>
    return protocolError "enclosure_execution_error" error.toString

/-- Handle bridge metadata request for client compatibility checks. -/
def handleGetInfo (runtime : Option EnclosureRuntime := none) : Json :=
  Json.mkObj [
    ("protocol_name", toJson "leancert-line-json"),
    ("framing", toJson "ndjson"),
    ("protocol_version", toJson bridgeApiVersion),
    ("bridge_api_version", toJson bridgeApiVersion),
    ("bridge_version", toJson bridgeVersion),
    ("lean_version", toJson leanVersion),
    ("leancert_version", toJson leanCertVersion),
    ("enclosure_profile", runtime.map profileToJson |>.getD Json.null),
    ("certificate_schemas", toJson [
      boundCertificateSchema, strictBoundCertificateSchema, adaptiveCertificateSchema,
      krawczykCertificateSchema,
      eventualCertificateSchema, scalarRootCertificateSchema, integralCertificateSchema,
      registeredEnclosureCertificateSchema]),
    ("verification_routes", toJson ["compiled_checker"]),
    ("operations", toJson [
      "ping", "get_info", "eval_interval", "eval_interval_dyadic",
      "eval_interval_affine", "global_min", "global_max", "global_min_dyadic",
      "global_max_dyadic", "global_min_affine", "global_max_affine", "check_bound",
      "check_strict_bound",
      "integrate", "find_roots", "find_unique_root", "verify_adaptive",
      "check_unique_system_root", "check_eventual_bound", "check_scalar_root",
      "check_integral", "check_registered_enclosure", "replay_registered_enclosure",
      "forward_interval", "deriv_interval"
    ]),
    ("capabilities", Json.mkObj [
      ("check_bound", Json.mkObj [
        ("schema_version", toJson "2.1"),
        ("request_schema", toJson boundRequestSchema),
        ("result_schema", toJson boundOutcomeSchema),
        ("certificate_schemas", toJson [boundCertificateSchema]),
        ("verification_routes", toJson ["compiled_checker"]),
        ("outcomes", toJson ["verified", "inconclusive", "unsupported", "domain_obstruction"]),
        ("backends", toJson ["rational_global_optimization"])
      ]),
      ("check_strict_bound", Json.mkObj [
        ("schema_version", toJson "2.7"),
        ("request_schema", toJson strictBoundRequestSchema),
        ("result_schema", toJson strictBoundOutcomeSchema),
        ("certificate_schemas", toJson [strictBoundCertificateSchema]),
        ("verification_routes", toJson ["compiled_checker"]),
        ("outcomes", toJson ["verified", "inconclusive", "unsupported", "domain_obstruction"]),
        ("backends", toJson ["rational_global_optimization"]),
        ("relations", toJson ["lt", "gt"])
      ]),
      ("verify_adaptive", Json.mkObj [
        ("schema_version", toJson "2.2"),
        ("request_schema", toJson adaptiveRequestSchema),
        ("result_schema", toJson adaptiveOutcomeSchema),
        ("certificate_schemas", toJson [adaptiveCertificateSchema]),
        ("verification_routes", toJson ["compiled_checker"]),
        ("outcomes", toJson ["verified", "inconclusive", "unsupported", "domain_obstruction"]),
        ("backends", toJson ["rational_checked_global_optimization"])
      ]),
      ("check_unique_system_root", Json.mkObj [
        ("schema_version", toJson "2.3"),
        ("request_schema", toJson systemRootRequestSchema),
        ("result_schema", toJson systemRootOutcomeSchema),
        ("certificate_schemas", toJson [krawczykCertificateSchema]),
        ("verification_routes", toJson ["compiled_checker"]),
        ("outcomes", toJson ["verified", "candidate_rejected", "unsupported"]),
        ("backends", toJson ["rational_krawczyk"]),
        ("maximum_dimension", toJson 4)
      ]),
      ("check_eventual_bound", Json.mkObj [
        ("schema_version", toJson "2.4"),
        ("request_schema", toJson eventualRequestSchema),
        ("result_schema", toJson eventualOutcomeSchema),
        ("certificate_schemas", toJson [eventualCertificateSchema]),
        ("verification_routes", toJson ["compiled_checker"]),
        ("outcomes", toJson ["verified", "candidate_rejected", "inconclusive", "unsupported"]),
        ("backends", toJson ["rational_reciprocal_power"]),
        ("tail_family", toJson "nonnegative_rational_reciprocal_power_upper")
      ]),
      ("check_scalar_root", Json.mkObj [
        ("schema_version", toJson "2.5"),
        ("request_schema", toJson scalarRootRequestSchema),
        ("result_schema", toJson scalarRootOutcomeSchema),
        ("certificate_schemas", toJson [scalarRootCertificateSchema]),
        ("verification_routes", toJson ["compiled_checker"]),
        ("outcomes", toJson ["verified", "candidate_rejected", "unsupported"]),
        ("backends", toJson ["rational_scalar_root"]),
        ("claim_kinds", toJson ["exists", "unique", "excluded"])
      ]),
      ("check_integral", Json.mkObj [
        ("schema_version", toJson "2.6"),
        ("request_schema", toJson integralRequestSchema),
        ("result_schema", toJson integralOutcomeSchema),
        ("certificate_schemas", toJson [integralCertificateSchema]),
        ("verification_routes", toJson ["compiled_checker"]),
        ("outcomes", toJson ["verified", "candidate_rejected", "inconclusive",
          "unsupported", "domain_obstruction"]),
        ("backends", toJson ["rational_exact_polynomial", "rational_checked_partitions"]),
        ("relations", toJson ["eq", "lower", "upper"])
      ]),
      ("check_registered_enclosure", Json.mkObj [
        ("schema_version", toJson "2.8"),
        ("request_schema", toJson "check-registered-enclosure-request/1"),
        ("result_schema", toJson "registered-enclosure-outcome/1"),
        ("certificate_schemas", toJson [registeredEnclosureCertificateSchema]),
        ("replay_payload_schema", toJson registeredEnclosureReplayPayloadSchema),
        ("verification_routes", toJson ["kernel_proof", "fixed_checker_replay"]),
        ("outcomes", toJson ["verified", "candidate_rejected", "inconclusive",
          "unsupported", "domain_obstruction"]),
        ("relations", toJson ["le", "lt", "ge", "gt"]),
        ("profile_required", toJson true),
        ("profile_loaded", toJson runtime.isSome)
      ]),
      ("replay_registered_enclosure", Json.mkObj [
        ("schema_version", toJson "2.8"),
        ("request_schema", toJson "replay-registered-enclosure-request/1"),
        ("result_schema", toJson "registered-enclosure-outcome/1"),
        ("certificate_schemas", toJson [registeredEnclosureCertificateSchema]),
        ("verification_routes", toJson ["fixed_checker_replay"]),
        ("candidate_execution", toJson false),
        ("profile_required", toJson true),
        ("profile_loaded", toJson runtime.isSome)
      ])
    ]),
    ("expression_nodes", toJson [
      "const", "var", "neg", "add", "sub", "mul", "div", "pow",
      "sin", "cos", "tan", "exp", "log", "sqrt", "inv", "atan",
      "arsinh", "atanh", "sinc", "erf", "abs", "sinh", "cosh",
      "tanh", "min", "max"
    ])
  ]

/-! ## 5. Main Event Loop -/

/-- Process one request from the custom line-delimited JSON protocol. -/
unsafe def processRequest (runtime : Option EnclosureRuntime) (line : String) : IO Unit := do
  let respond (j : Json) : IO Unit := do
    IO.println j.compress
    (← IO.getStdout).flush

  match Json.parse line with
  | Except.error e =>
    respond (protocolError "parse_error" s!"JSON parse error: {e}")
  | Except.ok j =>
    let reqId := j.getObjVal? "id" |>.toOption

    match j.getObjValAs? String "method" with
    | Except.error _ =>
      respond (protocolError "invalid_request" "Missing 'method' field")
    | Except.ok method =>
      let args := match j.getObjVal? "params" with
        | Except.ok a => a
        | Except.error _ => Json.mkObj []

      if method == "check_registered_enclosure" then
        let result ← dispatchCheckRegisteredEnclosure runtime args
        let final := match reqId with
          | some id => result.setObjVal! "id" id
          | none => result
        respond final
        return

      if method == "replay_registered_enclosure" then
        let result ← dispatchReplayRegisteredEnclosure runtime args
        let final := match reqId with
          | some id => result.setObjVal! "id" id
          | none => result
        respond final
        return

      let result := match method with
        | "eval_interval" =>
          match fromJson? (α := EvalRequest) args with
          | Except.ok req => Json.mkObj [("result", handleEvalInterval req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid eval_interval params: {e}"

        | "eval_interval_dyadic" =>
          match fromJson? (α := EvalDyadicRequest) args with
          | Except.ok req => Json.mkObj [("result", handleEvalIntervalDyadic req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid eval_interval_dyadic params: {e}"

        | "eval_interval_affine" =>
          match fromJson? (α := EvalAffineRequest) args with
          | Except.ok req => Json.mkObj [("result", handleEvalIntervalAffine req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid eval_interval_affine params: {e}"

        | "global_min" =>
          match fromJson? (α := OptimizeRequest) args with
          | Except.ok req => Json.mkObj [("result", handleGlobalMin req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid global_min params: {e}"

        | "global_max" =>
          match fromJson? (α := OptimizeRequest) args with
          | Except.ok req => Json.mkObj [("result", handleGlobalMax req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid global_max params: {e}"

        | "global_min_dyadic" =>
          match fromJson? (α := OptimizeDyadicRequest) args with
          | Except.ok req => Json.mkObj [("result", handleGlobalMinDyadic req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid global_min_dyadic params: {e}"

        | "global_max_dyadic" =>
          match fromJson? (α := OptimizeDyadicRequest) args with
          | Except.ok req => Json.mkObj [("result", handleGlobalMaxDyadic req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid global_max_dyadic params: {e}"

        | "global_min_affine" =>
          match fromJson? (α := OptimizeAffineRequest) args with
          | Except.ok req => Json.mkObj [("result", handleGlobalMinAffine req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid global_min_affine params: {e}"

        | "global_max_affine" =>
          match fromJson? (α := OptimizeAffineRequest) args with
          | Except.ok req => Json.mkObj [("result", handleGlobalMaxAffine req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid global_max_affine params: {e}"

        | "check_bound" =>
          match fromJson? (α := CheckBoundRequest) args with
          | Except.ok req => Json.mkObj [("result", handleCheckBound req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid check_bound params: {e}"

        | "check_strict_bound" =>
          match fromJson? (α := CheckStrictBoundRequest) args with
          | Except.ok req => Json.mkObj [("result", handleCheckStrictBound req)]
          | Except.error e =>
              protocolError "invalid_params" s!"Invalid check_strict_bound params: {e}"

        | "integrate" =>
          match fromJson? (α := IntegrateRequest) args with
          | Except.ok req => Json.mkObj [("result", handleIntegrate req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid integrate params: {e}"

        | "find_roots" =>
          match fromJson? (α := FindRootsRequest) args with
          | Except.ok req => Json.mkObj [("result", handleFindRoots req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid find_roots params: {e}"

        | "find_unique_root" =>
          match fromJson? (α := FindUniqueRootRequest) args with
          | Except.ok req => Json.mkObj [("result", handleFindUniqueRoot req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid find_unique_root params: {e}"

        | "verify_adaptive" =>
          match fromJson? (α := VerifyAdaptiveRequest) args with
          | Except.ok req => Json.mkObj [("result", handleVerifyAdaptive req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid verify_adaptive params: {e}"

        | "check_unique_system_root" =>
          match fromJson? (α := CheckUniqueSystemRootRequest) args with
          | Except.ok req => Json.mkObj [("result", handleCheckUniqueSystemRoot req)]
          | Except.error e =>
              protocolError "invalid_params" s!"Invalid check_unique_system_root params: {e}"

        | "check_eventual_bound" =>
          match fromJson? (α := CheckEventualBoundRequest) args with
          | Except.ok req => Json.mkObj [("result", handleCheckEventualBound req)]
          | Except.error e =>
              protocolError "invalid_params" s!"Invalid check_eventual_bound params: {e}"

        | "check_scalar_root" =>
          match fromJson? (α := CheckScalarRootRequest) args with
          | Except.ok req => Json.mkObj [("result", handleCheckScalarRoot req)]
          | Except.error e =>
              protocolError "invalid_params" s!"Invalid check_scalar_root params: {e}"

        | "check_integral" =>
          match fromJson? (α := CheckIntegralRequest) args with
          | Except.ok req => Json.mkObj [("result", handleCheckIntegral req)]
          | Except.error e =>
              protocolError "invalid_params" s!"Invalid check_integral params: {e}"

        | "forward_interval" =>
          match fromJson? (α := ForwardIntervalRequest) args with
          | Except.ok req => Json.mkObj [("result", handleForwardInterval req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid forward_interval params: {e}"

        | "deriv_interval" =>
          match fromJson? (α := DerivIntervalRequest) args with
          | Except.ok req => Json.mkObj [("result", handleDerivInterval req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid deriv_interval params: {e}"

        | "get_info" =>
          Json.mkObj [("result", handleGetInfo runtime)]

        | "ping" =>
          Json.mkObj [("result", "pong")]

        | other =>
          protocolError "unknown_method" s!"Unknown method: {other}"

      -- Attach ID if present
      let final := match reqId with
        | some id => result.setObjVal! "id" id
        | none => result

      respond final

/-! ## Process entry point -/

/-- Run the Bridge with the downstream modules statically imported by the
executable's root. The immutable JSON profile may only select from this list. -/
unsafe def run (args : List String) (staticProfileModules : Array Name) : IO Unit := do
  let runtime ← match args with
    | [] => pure none
    | ["--enclosure-profile", path] =>
        some <$> loadEnclosureRuntime path staticProfileModules
    | _ => throw (IO.userError
        "usage: lean_bridge [--enclosure-profile PROFILE.json]")
  let stdin ← IO.getStdin
  repeat do
    let line ← stdin.getLine
    if line.isEmpty then break
    -- Trim whitespace
    let trimmed := line.trimAscii.toString
    if !trimmed.isEmpty then
      processRequest runtime trimmed

end LeanCert.Bridge
