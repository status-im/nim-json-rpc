# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

mode = ScriptMode.Verbose

packageName   = "json_rpc"
version       = "0.4.2"
author        = "Status Research & Development GmbH"
description   = "Ethereum remote procedure calls"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

### Dependencies
requires "nim >= 1.6.0",
         "stew",
         "nimcrypto",
         "stint",
         "chronos#head",
         "httputils#head",
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
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:refc -r", path

proc buildOnly(args, path: string) =
  build args, path
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:refc -r", path

task test, "run tests":
  run "", "tests/all"

  when not defined(windows):
    # on windows, socker server build failed
    buildOnly "-d:\"chronicles_sinks=textlines[dynamic],json[dynamic]\"", "tests/all"
