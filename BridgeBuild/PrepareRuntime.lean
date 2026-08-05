/-
Copyright (c) 2024 LeanCert Contributors. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: LeanCert Contributors
-/

import Lean

/-!
# Managed-runtime artifact preparation

Hydrate Mathlib's platform artifacts and build the ordinary Bridge executable
inside the environment that `lean-runtime` will publish. This target contains
no mathematical or provenance claims; it is a cross-platform Lake build helper.
-/

private def runLake (arguments : Array String) : IO UInt32 := do
  let result ← IO.Process.output {
    cmd := "lake"
    args := arguments
    -- This helper is itself launched through `lake exe`, which augments these
    -- variables for the helper target. A nested Lake invocation must discover
    -- the enclosing workspace afresh; inheriting the outer target's paths
    -- prevents Mathlib's cache executable from resolving `Mathlib`.
    env := #[
      ("LEAN_PATH", none),
      ("LEAN_SRC_PATH", none)
    ]
  }
  IO.print result.stdout
  IO.eprint result.stderr
  return result.exitCode

def main : IO UInt32 := do
  let hydration ← runLake #["exe", "cache", "get"]
  if hydration != 0 then
    return hydration
  runLake #["build", "@LeanCertBridge/lean_bridge"]
