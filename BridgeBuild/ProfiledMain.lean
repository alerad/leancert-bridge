/-
Copyright (c) 2026 LeanCert Contributors. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import LeanBridge
import BridgeBuild.TestEnclosureExtension

/-!
Integration-test entry point for the downstream profiled-Bridge pattern.
The imported module and the declared static module must agree.
-/

unsafe def main (args : List String) : IO Unit :=
  LeanCert.Bridge.run args #[`BridgeBuild.TestEnclosureExtension]
