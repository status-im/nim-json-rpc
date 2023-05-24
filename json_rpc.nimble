mode = ScriptMode.Verbose

packageName   = "json_rpc"
version       = "0.0.2"
author        = "Status Research & Development GmbH"
description   = "Ethereum remote procedure calls"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

### Dependencies
requires "nim >= 1.6.0",
         "stew",
         "nimcrypto",
         "stint",
         "chronos",
         "httputils",
         "chronicles",
         "websock",
         "json_serialization",
         "unittest2"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipParentCfg --skipUserCfg --outdir:build --nimcache:build/nimcache -f" &
  " --threads:on -d:chronicles_log_level=ERROR"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path

proc buildBinary(name: string, srcDir = "./", params = "", cmdParams = "") =
  if not dirExists "build":
    mkDir "build"
  exec "nim " & getEnv("TEST_LANG", "c") & " " & getEnv("NIMFLAGS") &
  " -r -f --skipUserCfg:on --skipParentCfg:on --verbosity:0" &
  " --debuginfo --path:'.' --threads:on -d:chronicles_log_level=ERROR" &
  " --styleCheck:usages --styleCheck:hint" &
  " --hint[XDeclaredButNotUsed]:off --hint[Processing]:off " &
  " --out:./build/" & name & " " & params & " " & srcDir & name & ".nim" &
  " " & cmdParams

task test, "run tests":
  run "", "tests/all"
