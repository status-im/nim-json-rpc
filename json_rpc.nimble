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
         "chronicles"

proc configForTests() =
  --hints: off
  --debuginfo
  --path: "."
  --run
  --forceBuild
  --threads: on
  # https://github.com/nim-lang/Nim/issues/8294#issuecomment-454556051
  if hostOS == "windows":
    --define: "chronicles_colors=NoColors"

task test, "run tests":
  configForTests()
  setCommand "c", "tests/all.nim"
