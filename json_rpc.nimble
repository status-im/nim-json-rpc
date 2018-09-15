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
         "asyncdispatch2",
         "httputils",
         "chronicles"

proc configForTests() =
  --hints: off
  --debuginfo
  --path: "."
  --run
  --forceBuild

task test, "run tests":
  configForTests()
  setCommand "c", "tests/all.nim"
