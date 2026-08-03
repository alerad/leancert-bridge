import Lake

open Lake DSL

/-- Whether one serialized module part contains regular `[init]` entries. -/
unsafe def modulePartHasInitializers (path : System.FilePath) : IO Bool := do
  let (data, _) ← Lean.CompactedRegion.read (α := Lean.ModuleData) path #[]
  return data.entries.any fun (name, entries) =>
    name == `Lean.regularInitAttr && !entries.isEmpty

/-- Detect initializer-bearing modules from Lean's generated artifacts rather
than guessing from namespaces or source syntax. Meta initializers live in the
`.olean` parts; runtime initializers may live in `.ir`. -/
unsafe def moduleHasInitializers (arts : ModuleOutputArtifacts) : IO Bool := do
  if ← modulePartHasInitializers arts.olean.path then return true
  if let some privateOLean := arts.oleanPrivate? then
    if ← modulePartHasInitializers privateOLean.path then return true
  if let some ir := arts.ir? then
    if ← modulePartHasInitializers ir.path then return true
  return false

/-
Windows executables have a hard limit of 65,535 exported symbols. An
interpreter-enabled executable normally asks every transitive module for its
`o.export` facet, which exceeds that limit for LeanCert's dependency graph.
Keep LeanCert's checked execution surface and modules with native initializer
entry points visible; route every other module to the ordinary non-exporting
object. This preserves dynamic environment initialization without exporting
the whole theorem dependency graph.
-/
@[«module_facet»]
unsafe abbrev windowsSafeOExport : ModuleFacetDecl :=
  .mk Module.oExportFacet <|
    mkFacetJobConfig (memoize := false) fun mod => do
      let isLeanCert :=
        mod.name == `LeanCert || mod.name.toString.startsWith "LeanCert."
      if !System.Platform.isWindows || isLeanCert then
        Module.oExportFacetConfig.run mod
      else
        let hasInitializers ← (← mod.leanArts.fetch).mapM (sync := true) fun arts =>
          moduleHasInitializers arts
        let exporting ← Module.oExportFacetConfig.run mod
        let hidden ← mod.oNoExport.fetch
        hasInitializers.bindM fun hasInitializers =>
          pure <| if hasInitializers then exporting else hidden

package «LeanCertBridge» where
  version := v!"0.1.0"

require leancert from git
  "https://github.com/alerad/leancert.git" @ "06cf139"

lean_lib BridgeBuild

/- Importable runtime used by standard and downstream-profiled executables. -/
lean_lib LeanBridge

@[default_target]
lean_exe lean_bridge where
  root := `BridgeMain
  supportInterpreter := false

/- Integration-test executable demonstrating the downstream profiled-root
pattern. Real downstream projects provide their own root importing their
registered enclosure modules. -/
lean_exe lean_bridge_profile_test where
  root := `BridgeBuild.ProfiledMain
  supportInterpreter := true
