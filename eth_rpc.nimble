packageName   = "eth_rpc"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "Ethereum remote procedure calls"
license       = "Apache License 2.0"
srcDir        = "src"

### Dependencies
requires "nim >= 0.17.3",
         "nimcrypto",
         "stint"

proc configForTests() =
  --hints: off
  --debuginfo
  --path: "."
  --run
  --forceBuild

task test, "run tests":
  configForTests()
  setCommand "c", "tests/all.nim"
