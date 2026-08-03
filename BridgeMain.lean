/-
Copyright (c) 2024 LeanCert Contributors. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: LeanCert Contributors
-/
import LeanBridge

/-! Standard Bridge entry point without statically linked downstream profiles. -/

unsafe def main (args : List String) : IO Unit :=
  LeanCert.Bridge.run args #[]
