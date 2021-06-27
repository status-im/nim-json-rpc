packageName   = "json_rpc"
version       = "0.0.2"
author        = "Status Research & Development GmbH"
description   = "Ethereum remote procedure calls"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

### Dependencies
requires "nim >= 1.2.0",
         "nimcrypto",
         "stint",
         "chronos",
         "httputils",
         "chronicles#ba2817f1",
         "https://github.com/status-im/nim-websock",
         "json_serialization"

proc getLang(): string =
  # Compilation language is controlled by TEST_LANG
  result = "c"
  if existsEnv"TEST_LANG":
    result = getEnv"TEST_LANG"

proc buildBinary(name: string, srcDir = "./", params = "", cmdParams = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  exec "nim " & lang & " --out:./build/" & name & " " & params & " " & srcDir & name & ".nim" & " " & cmdParams

task test, "run tests":
  buildBinary "all", "tests/", "-r -f --hints:off --debuginfo --path:'.' --threads:on -d:chronicles_log_level=ERROR", getLang()
