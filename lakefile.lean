import Lake

open Lake DSL

/-- Whether one serialized module part contains regular `[init]` entries. -/
def moduleDataHasInitializers (data : Lean.ModuleData) : Bool :=
  data.entries.any fun (name, entries) =>
    name == `Lean.regularInitAttr && !entries.isEmpty

/-- Load consecutive module-data parts, scan them for `[init]` entries, and
hand the backing regions to the caller. Every `ModuleData` reference dies when
this function returns, so the caller may safely free the regions. -/
unsafe def readPartsHaveInitializers (paths : Array System.FilePath) :
    IO (Bool × Array Lean.CompactedRegion) := do
  let parts ← Lean.readModuleDataParts paths
  let found := parts.any fun (data, _) => moduleDataHasInitializers data
  return (found, parts.map (·.2))

/-- Detect initializer-bearing modules from Lean's generated artifacts rather
than guessing from namespaces or source syntax. Meta initializers live in the
`.olean` parts; runtime initializers may live in `.ir`.

Module-system `.olean`/`.olean.server`/`.olean.private` parts are saved with
`saveModuleDataParts` and share compacted regions, so they must be loaded
together, in order, via `readModuleDataParts`; reading a later part on its own
dereferences pointers into the earlier parts and crashes Lake. The `.ir` part
has its own base address and may be read individually. Regions are freed after
each check (in reverse order, once no data references remain) so scanning the
whole import closure stays within memory. -/
unsafe def moduleHasInitializers (arts : ModuleOutputArtifacts) : IO Bool := do
  let mut oleanParts := #[arts.olean.path]
  if let some server := arts.oleanServer? then
    oleanParts := oleanParts.push server.path
    if let some priv := arts.oleanPrivate? then
      oleanParts := oleanParts.push priv.path
  let (found, oleanRegions) ← readPartsHaveInitializers oleanParts
  oleanRegions.reverse.forM (·.free)
  if found then return true
  let some ir := arts.ir? | return false
  let (irFound, irRegions) ← readPartsHaveInitializers #[ir.path]
  irRegions.reverse.forM (·.free)
  return irFound

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

/- Cross-platform artifact hook used by managed runtime environments. -/
lean_exe lean_bridge_runtime_prepare where
  root := `BridgeBuild.PrepareRuntime

/- Integration-test executable demonstrating the downstream profiled-root
pattern. Real downstream projects provide their own root importing their
registered enclosure modules. -/
lean_exe lean_bridge_profile_test where
  root := `BridgeBuild.ProfiledMain
  supportInterpreter := true
