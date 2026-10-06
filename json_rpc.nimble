# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

mode = ScriptMode.Verbose

packageName   = "json_rpc"
version       = "0.7.0"
author        = "Status Research & Development GmbH"
description   = "Ethereum remote procedure calls"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

### Dependencies
requires "nim >= 2.0.10",
         "chronicles >= 0.12.0",
         "chronos >= 4.0.3 & < 5.0.0",
         "httputils >= 0.3.0",
         "json_serialization >= 0.4.2",
         "nimcrypto >= 0.7.0",
         "serialization >= 0.4.4",
         "stew >= 0.5.0",
         "stint >= 0.9.0",
         "unittest2 >= 0.2.0",
         "websock >= 0.2.1 & < 0.5.0"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]
let platform = getEnv("PLATFORM", "")
let testArguments = [
  "",
  "-d:release",
]

from std/os import quoteShell

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0") &
  " --skipParentCfg --skipUserCfg --outdir:build -f " &
  quoteShell("--nimcache:build/nimcache/$projectName")

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path

task test, "Run all tests":
  for args in testArguments:
    run args & " --mm:refc", "tests/all"
    run args & " --mm:orc", "tests/all"

  when not defined(windows):
    # on windows, socker server build failed
    let args = "-d:chronicles_log_level=TRACE -d:\"chronicles_sinks=textlines[dynamic],json[dynamic]\""
    build args & " --mm:refc", "tests/all"
    build args & " --mm:orc", "tests/all"

task test_asan, "Run all tests with ASAN":
  if platform != "x86":
    # https://clang.llvm.org/docs/AddressSanitizer.html
    putEnv("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=1")
    # https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
    putEnv("UBSAN_OPTIONS", "print_stacktrace=1")
    let asanArgs =
      " --mm:orc -d:useMalloc --cc:clang --debugger:native" &
      " --passC:-fsanitize=address,undefined" &
      " --passL:-fsanitize=address,undefined" &
      " --passC:-fno-sanitize-recover=undefined" &
      " --passC:-fno-sanitize-merge" &
      " --passC:-fno-omit-frame-pointer"
    for args in testArguments:
      run args & asanArgs, "tests/all"

task examples, "Run examples":
  # Run book examples
  for file in listFiles("docs/examples"):
    if file.endsWith("_sigs_def.nim"):
      continue
    elif file.endsWith("_server.nim") and not file.endsWith("test_server.nim"):
      # Avoid serve forever; the clients import them
      continue
    elif file.endsWith(".nim"):
      run "--mm:refc", file
      run "--mm:orc", file

task docs, "Generate API documentation":
  exec "mdbook build docs"
  for file in ["rpcclient.nim", "rpcserver.nim", "rpcproxy.nim"]:
    exec nimc & " doc " &
      "--git.url:https://github.com/status-im/nim-json-rpc --git.commit:master --outdir:docs/book/api --project json_rpc/" & file

task mdbook, "Install mdbook (requires cargo)":
  exec "cargo install --force mdbook@0.4.52 mdbook-toc@0.14.2 mdbook-open-on-gh@2.4.3 mdbook-admonish@1.20.0 mdbook-shiftinclude@0.1.0"
