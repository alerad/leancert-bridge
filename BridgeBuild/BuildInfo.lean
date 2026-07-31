/-
Generated release builds replace these development values before compiling.
The module remains checked in so local builds are deterministic and require no
network or Git metadata.
-/
namespace LeanCert.Bridge.BuildInfo

def sourceRevision : String := "development"
def sourceDigest : String := "unavailable"
def environmentDigest : String := "unavailable"
def profile : String := "development"

end LeanCert.Bridge.BuildInfo
