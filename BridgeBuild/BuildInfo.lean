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
def leanToolchain : String := "leanprover/lean4:v4.32.2"
def leanCertSource : String := "https://github.com/alerad/leancert.git"
def leanCertInputRevision : String := "v4.32.2.3"
def leanCertResolvedRevision : String := "6f0c9ae5bcd5e40463d9771f06b33ef145c242f6"

end LeanCert.Bridge.BuildInfo
