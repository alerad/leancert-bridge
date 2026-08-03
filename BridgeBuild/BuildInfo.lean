namespace LeanCert.Bridge.BuildInfo

def sourceRevision : String := "development"
def sourceDigest : String := "sha256:b5ad05a38c35bf2358f665164b4b2714743a05a3ca08546cfcccc2b1a3e71f9a"
def environmentDigest : String := "sha256:d6c9b966d1bc870606af5cb3936a158e9c76c292188a7e28670be3dbe15003f8"
def profile : String := "development"

def leanToolchain : String := "leanprover/lean4:v4.32.2"
def leanCertSource : String := "https://github.com/alerad/leancert.git"
def leanCertInputRevision : String := "06cf139"
def leanCertResolvedRevision : String := "06cf13980fde15b21fe2600cbb8b8d4e0e612f3c"

end LeanCert.Bridge.BuildInfo
