packageName   = "json_rpc"
version       = "0.0.2"
author        = "Status Research & Development GmbH"
description   = "Ethereum remote procedure calls"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

### Dependencies
requires "nim >= 0.17.3",
         "nimcrypto",
         "stint",
         "chronos",
         "httputils",
         "chronicles",
         "news >= 0.4 & < 0.5",
         "chronicles",
         "json_serialization"

proc buildBinary(name: string, srcDir = "./", params = "", cmdParams = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  exec "nim " & lang & " --out:./build/" & name & " " & params & " " & srcDir & name & ".nim" & " " & cmdParams

task test, "run tests":
  buildBinary "all", "tests/", "-r -f --hints:off --debuginfo --path:'.' --threads:on -d:chronicles_log_level=ERROR"

