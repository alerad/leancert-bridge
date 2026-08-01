/-
Copyright (c) 2024 LeanCert Contributors. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: LeanCert Contributors
-/
import Lean.Data.Json
import BridgeBuild.BuildInfo
import LeanCert.Core.Expr
import LeanCert.Engine.IntervalEval
import LeanCert.Engine.IntervalEvalDyadic
import LeanCert.Engine.IntervalEvalAffine
import LeanCert.Engine.Optimization.Global
import LeanCert.Engine.Optimization.Gradient
import LeanCert.Engine.Integrate
import LeanCert.Engine.RootFinding.KrawczykCandidate
import LeanCert.Validity.Bounds
import LeanCert.ML.Distillation

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
def bridgeApiVersion : String := "2.3.0"

/-- Bridge binary version (decoupled from API version). -/
def bridgeVersion : String := "0.5.0"

/-- Lean toolchain version used to build this bridge binary. -/
def leanVersion : String := Lean.versionString

/-- LeanCert release selected by `lakefile.toml`. -/
def leanCertVersion : String := "4.32.2.3"

/-- Certificate/result schema emitted by checked bound operations. -/
def boundCertificateSchema : String := "bound-check/2"

/-- Exact checker-input schema embedded in replayable bound certificates. -/
def boundReplayPayloadSchema : String := "global-opt-bound-replay/1"

/-- Retained input/result schema for the checked adaptive optimizer. -/
def adaptiveCertificateSchema : String := "adaptive-bound-check/1"
def adaptiveReplayPayloadSchema : String := "checked-global-opt-bound/1"

/-- Retained fixed Krawczyk checker input for unique nonlinear-system roots. -/
def krawczykCertificateSchema : String := "krawczyk-check/1"
def krawczykReplayPayloadSchema : String := "checked-unique-system-root/1"

/-- Stable request and outcome schemas for the checked bound operation. -/
def boundRequestSchema : String := "check-bound-request/1"
def boundOutcomeSchema : String := "bound-outcome/1"
def adaptiveRequestSchema : String := "verify-adaptive-request/1"
def adaptiveOutcomeSchema : String := "adaptive-bound-outcome/1"
def systemRootRequestSchema : String := "check-unique-system-root-request/1"
def systemRootOutcomeSchema : String := "unique-system-root-outcome/1"

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

/-- Handle bridge metadata request for client compatibility checks. -/
def handleGetInfo : Json :=
  Json.mkObj [
    ("protocol_name", toJson "leancert-line-json"),
    ("framing", toJson "ndjson"),
    ("protocol_version", toJson bridgeApiVersion),
    ("bridge_api_version", toJson bridgeApiVersion),
    ("bridge_version", toJson bridgeVersion),
    ("lean_version", toJson leanVersion),
    ("leancert_version", toJson leanCertVersion),
    ("build", Json.mkObj [
      ("source_revision", toJson LeanCert.Bridge.BuildInfo.sourceRevision),
      ("source_digest", toJson LeanCert.Bridge.BuildInfo.sourceDigest),
      ("environment_digest", toJson LeanCert.Bridge.BuildInfo.environmentDigest),
      ("profile", toJson LeanCert.Bridge.BuildInfo.profile)
    ]),
    ("dependencies", Json.mkObj [
      ("lean", Json.mkObj [
        ("toolchain", toJson LeanCert.Bridge.BuildInfo.leanToolchain)
      ]),
      ("leancert", Json.mkObj [
        ("source", toJson LeanCert.Bridge.BuildInfo.leanCertSource),
        ("input_revision", toJson LeanCert.Bridge.BuildInfo.leanCertInputRevision),
        ("resolved_revision", toJson LeanCert.Bridge.BuildInfo.leanCertResolvedRevision)
      ])
    ]),
    ("certificate_schemas", toJson [
      boundCertificateSchema, adaptiveCertificateSchema, krawczykCertificateSchema]),
    ("verification_routes", toJson ["compiled_checker"]),
    ("operations", toJson [
      "ping", "get_info", "eval_interval", "eval_interval_dyadic",
      "eval_interval_affine", "global_min", "global_max", "global_min_dyadic",
      "global_max_dyadic", "global_min_affine", "global_max_affine", "check_bound",
      "integrate", "find_roots", "find_unique_root", "verify_adaptive",
      "check_unique_system_root",
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

/-- Structured infrastructure error used by Bridge Contract 2.0. -/
def protocolError (code message : String) : Json :=
  Json.mkObj [("error", Json.mkObj [
    ("code", toJson code),
    ("message", toJson message)
  ])]

/-- Process one request from the custom line-delimited JSON protocol. -/
def processRequest (line : String) : IO Unit := do
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

        | "forward_interval" =>
          match fromJson? (α := ForwardIntervalRequest) args with
          | Except.ok req => Json.mkObj [("result", handleForwardInterval req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid forward_interval params: {e}"

        | "deriv_interval" =>
          match fromJson? (α := DerivIntervalRequest) args with
          | Except.ok req => Json.mkObj [("result", handleDerivInterval req)]
          | Except.error e => protocolError "invalid_params" s!"Invalid deriv_interval params: {e}"

        | "get_info" =>
          Json.mkObj [("result", handleGetInfo)]

        | "ping" =>
          Json.mkObj [("result", "pong")]

        | other =>
          protocolError "unknown_method" s!"Unknown method: {other}"

      -- Attach ID if present
      let final := match reqId with
        | some id => result.setObjVal! "id" id
        | none => result

      respond final

end LeanCert.Bridge

/-- Main entry point: read lines from stdin, process each as a request -/
def main : IO Unit := do
  let stdin ← IO.getStdin
  repeat do
    let line ← stdin.getLine
    if line.isEmpty then break
    -- Trim whitespace
    let trimmed := line.trimAscii.toString
    if !trimmed.isEmpty then
      LeanCert.Bridge.processRequest trimmed
