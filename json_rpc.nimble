packageName   = "json_rpc"
version       = "0.0.2"
author        = "Status Research & Development GmbH"
description   = "Ethereum remote procedure calls"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

### Dependencies
requires "nim >= 1.2.0",
         "stew",
         "nimcrypto",
         "stint",
         "chronos",
         "httputils",
         "chronicles",
         "https://github.com/status-im/news#status",
         "websock",
         "json_serialization"

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
  buildBinary "all", "tests/",
    params = "-d:json_rpc_websocket_package=websock"

  buildBinary "all", "tests/",
    params = "-d:json_rpc_websocket_package=news"
