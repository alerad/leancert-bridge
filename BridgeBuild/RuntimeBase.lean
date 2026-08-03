/-
Copyright (c) 2024 LeanCert Contributors. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: LeanCert Contributors
-/

import Lean.Data.Json
import Lean.Elab.Frontend
import LeanCert.Core.Expr
import LeanCert.Engine.IntervalEval
import LeanCert.Engine.IntervalEvalDyadic
import LeanCert.Engine.IntervalEvalAffine
import LeanCert.Engine.Algebra.QPolyIntegral
import LeanCert.Engine.Optimization.Global
import LeanCert.Engine.Optimization.Gradient
import LeanCert.Engine.Integrate
import LeanCert.Engine.RootFinding.KrawczykCandidate
import LeanCert.Validity.Bounds
import LeanCert.Validity.Eventual
import LeanCert.Validity.Integration
import LeanCert.ML.Distillation
import LeanCert.Tactic.Extension
import LeanCert.Tactic.Extension.Execute

/-!
# Statically linked Bridge runtime

This module is the authoritative import root for code linked into `lean_bridge`.
The registered-enclosure loader uses its import closure to distinguish modules
whose native initializers already ran at process startup from genuinely dynamic
profile modules whose initializers must be interpreted.
-/
