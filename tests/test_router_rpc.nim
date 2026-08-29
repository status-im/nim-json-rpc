# json-rpc
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2,
  ../json_rpc/router,
  json_serialization/std/options,
  json_serialization/pkg/results,
  ./private/helpers

var server = RpcRouter()

type
  OptAlias[T] = results.Opt[T]

server.rpc("std_option") do(A: int, B: Option[int], C: string, D: Option[int], E: Option[string]) -> string:
  var res = "A: " & $A
  res.add ", B: " & $B.get(99)
  res.add ", C: " & C
  res.add ", D: " & $D.get(77)
  res.add ", E: " & E.get("none")
  return res

server.rpc("results_opt") do(A: int, B: Opt[int], C: string, D: Opt[int], E: Opt[string]) -> string:
  var res = "A: " & $A
  res.add ", B: " & $B.get(99)
  res.add ", C: " & C
  res.add ", D: " & $D.get(77)
  res.add ", E: " & E.get("none")
  return res

server.rpc("mixed_opt") do(A: int, B: Opt[int], C: string, D: Option[int], E: Opt[string]) -> string:
  var res = "A: " & $A
  res.add ", B: " & $B.get(99)
  res.add ", C: " & C
  res.add ", D: " & $D.get(77)
  res.add ", E: " & E.get("none")
  return res

server.rpc("alias_opt") do(A: int, B: OptAlias[int], C: string, D: Option[int], E: OptAlias[string]) -> string:
  var res = "A: " & $A
  res.add ", B: " & $B.get(99)
  res.add ", C: " & C
  res.add ", D: " & $D.get(77)
  res.add ", E: " & E.get("none")
  return res

server.rpc("noParams") do() -> int:
  return 123

server.rpc("emptyParams"):
  return %777

server.rpc("comboParams") do(a, b, c: int) -> int:
  return a+b+c

server.rpc("returnJsonString") do(a, b, c: int) -> JsonString:
  return JsonString($(a+b+c))

server.rpc("serializedFN") do(a{.serializedFieldName: "result".}: int) -> int:
  return a

server.rpc("empty") do() -> void:
  discard

server.rpc(JrpcConv):
  proc rpcCtxAsync(s: string): string {.async.} =
    await noCancel sleepAsync(0)
    return "ret1 " & s

  proc rpcCtxAsyncNoRaises(s: string): string {.async: (raises: []).} =
    await noCancel sleepAsync(0)
    return "ret2 " & s

  proc rpcCtxAsyncWithRaises(s: string): string {.async: (raises: [ValueError]).} =
    raise (ref ValueError)(msg: "err")

  proc rpcCtxSync(s: string): string =
    return "ret3 " & s

  proc rpcCtxSyncNoRaises(s: string): string {.raises: [].} =
    return "ret4 " & s

  proc rpcCtxSyncWithRaises(s: string): string {.raises: [ValueError].} =
    raise (ref ValueError)(msg: "err")

  proc rpcCtxAsyncEmpty(s: string): void {.async.} =
    discard

  proc rpcCtxSyncEmpty(s: string): void =
    discard

  proc emptyErrorMsg(): string {.raises: [ValueError].} =
    raise (ref ValueError)(msg: "")

func req(meth: string, params: string): string =
  """{"jsonrpc":"2.0", "method": """ &
    "\"" & meth & "\", \"params\": " & params & """, "id":0}"""

func notif(meth: string, params: string): string =
  """{"jsonrpc":"2.0", "method": """ &
    "\"" & meth & "\", \"params\": " & params & """}"""

template test_optional(meth: static[string]) =
  test meth & " B E, positional":
    let n = req(meth, "[44, null, \"apple\", 33]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"A: 44, B: 99, C: apple, D: 33, E: none","id":0}"""

  test meth & " B D E, positional":
    let n = req(meth, "[44, null, \"apple\"]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"A: 44, B: 99, C: apple, D: 77, E: none","id":0}"""

  test meth & " D E, positional":
    let n = req(meth, "[44, 567, \"apple\"]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"A: 44, B: 567, C: apple, D: 77, E: none","id":0}"""

  test meth & " D wrong E, positional":
    let n = req(meth, "[44, 567, \"apple\", \"banana\"]")
    let res = waitFor server.route(n)
    when meth == "std_option":
      check res == """{"jsonrpc":"2.0","error":{"code":-32602,"message":"`std_option` raised an exception","data":"Parameter [D] of type 'Option[system.int]' could not be decoded: number expected"},"id":0}"""
    elif meth == "results_opt":
      check res == """{"jsonrpc":"2.0","error":{"code":-32602,"message":"`results_opt` raised an exception","data":"Parameter [D] of type 'Opt[system.int]' could not be decoded: number expected"},"id":0}"""
    elif meth == "mixed_opt":
      check res == """{"jsonrpc":"2.0","error":{"code":-32602,"message":"`mixed_opt` raised an exception","data":"Parameter [D] of type 'Option[system.int]' could not be decoded: number expected"},"id":0}"""
    else:
      check res == """{"jsonrpc":"2.0","error":{"code":-32602,"message":"`alias_opt` raised an exception","data":"Parameter [D] of type 'Option[system.int]' could not be decoded: number expected"},"id":0}"""

  test meth & " D extra, positional":
    let n = req(meth, "[44, 567, \"apple\", 999, \"banana\", true]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"A: 44, B: 567, C: apple, D: 999, E: banana","id":0}"""

  test meth & " B D E, named":
    let n = req(meth, """{"A": 33, "C":"banana" }""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"A: 33, B: 99, C: banana, D: 77, E: none","id":0}"""

  test meth & " B E, D front, named":
    let n = req(meth, """{"D": 8887, "A": 33, "C":"banana" }""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"A: 33, B: 99, C: banana, D: 8887, E: none","id":0}"""

  test meth & " B E, D front, extra X, named":
    let n = req(meth, """{"D": 8887, "X": false , "A": 33, "C":"banana"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"A: 33, B: 99, C: banana, D: 8887, E: none","id":0}"""

suite "rpc router":
  test "no params":
    let n = req("noParams", "[]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":123,"id":0}"""

  test "no params with params":
    let n = req("noParams", "[123]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","error":{"code":-32602,"message":"`noParams` raised an exception","data":"Expected 0 JSON parameter(s) but got 1"},"id":0}"""

  test_optional("std_option")
  test_optional("results_opt")
  test_optional("mixed_opt")
  test_optional("alias_opt")

  test "empty params":
    let n = req("emptyParams", "[]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":777,"id":0}"""

  test "combo params":
    let n = req("comboParams", "[6,7,8]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":21,"id":0}"""

  test "return json string":
    let n = req("returnJsonString", "[6,7,8]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":21,"id":0}"""

  test "Custom parameter field name":
    let n = req("serializedFN", """{"result": 3}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":3,"id":0}"""

  test "Notification":
    let n = notif("emptyParams", """{"result": 3}""")
    let res = waitFor server.route(n)
    check res == ""

  test "Batch notification":
    let n = "[" & notif("emptyParams", """{"result": 3}""") & "]"
    let res = waitFor server.route(n)
    check res == ""

  test "Mixed notification/req":
    let n =
      "[" & notif("emptyParams", """{"result": 3}""") & "," & req("emptyParams", "[]") &
      "]"
    let res = waitFor server.route(n)
    check res == """[{"jsonrpc":"2.0","result":777,"id":0}]"""

  test "Empty response":
    let n = req("empty", """{"result": "foo"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":null,"id":0}"""

# https://www.jsonrpc.org/specification#error_object
suite "rpc router error codes":
  test "invalid JSON is a parse error":
    let res1 = waitFor server.route("{ this is not valid json }")
    check res1 == """{"jsonrpc":"2.0","error":{"code":-32700,"message":"string expected"},"id":null}"""

    let res2 = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams"""")
    check res2 == """{"jsonrpc":"2.0","error":{"code":-32700,"message":"'}' expected"},"id":null}"""

    let res3 = waitFor server.route("""[{"jsonrpc":"2.0","method":"noParams"}""")
    check res3 == """{"jsonrpc":"2.0","error":{"code":-32700,"message":"']' expected"},"id":null}"""

  test "non object/array request is an invalid request":
    let res1 = waitFor server.route("123")
    check res1 == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"RequestBatch must be either array or object, got=Number"},"id":null}"""

    let res2 = waitFor server.route("null")
    check res2 == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"RequestBatch must be either array or object, got=Null"},"id":null}"""

  test "empty batch is an invalid request":
    let res = waitFor server.route("[]")
    check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Batch must contain at least one message"},"id":null}"""

  test "batch of non requests is an invalid request":
    let res = waitFor server.route("[1,2,3]")
    check res == """{"jsonrpc":"2.0","error":{"code":-32700,"message":"'{' expected"},"id":null}"""

  test "missing or invalid jsonrpc version is an invalid request":
    let res1 = waitFor server.route("""{"method":"noParams","id":0}""")
    check res1 == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":null}"""

    let res2 = waitFor server.route("""{"jsonrpc":"1.0","method":"noParams","id":0}""")
    check res2 == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid JSON-RPC version, want=\"2.0\" got=\"1.0\""},"id":null}"""

    let res3 = waitFor server.route("""{"jsonrpc":2.0,"method":"noParams","id":0}""")
    check res3 == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid JSON-RPC version, want=\"2.0\" got=2.0"},"id":null}"""

  test "missing or invalid method is an invalid request":
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","id":0}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":null}"""
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":123,"id":0}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32700,"message":"string expected"},"id":null}"""
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":null,"id":"abc"}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32700,"message":"string expected"},"id":null}"""

  test "invalid id is an invalid request":
    # the `id` is what cannot be detected here, so it is reported as null
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams","id":{}}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid RequestId, must be Number, String, or Null, got=Object"},"id":null}"""
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams","id":[0]}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid RequestId, must be Number, String, or Null, got=Array"},"id":null}"""
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams","id":true}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid RequestId, must be Number, String, or Null, got=Bool"},"id":null}"""
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams","id":1.5}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32700,"message":"invalid integer value"},"id":null}"""

  test "unstructured params are an invalid request":
    # `Invalid params` is not a JSON decode error; it's for failing
    # to pass params to the method
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams","params":"abc","id":0}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"RequestParam must be either array or object, got=String"},"id":null}"""
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams","params":123,"id":"abc"}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"RequestParam must be either array or object, got=Number"},"id":null}"""
    block:
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams","params":null,"id":0}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"RequestParam must be either array or object, got=Null"},"id":null}"""
    block:
      # not a valid request object, hence not a notification either; the spec
      # answers those with a null id
      let res = waitFor server.route("""{"jsonrpc":"2.0","method":"noParams","params":"abc"}""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"RequestParam must be either array or object, got=String"},"id":null}"""
    block:
      # within a batch there is no single id to report back
      let res = waitFor server.route("""[{"jsonrpc":"2.0","method":"noParams","params":"abc","id":0}]""")
      check res == """{"jsonrpc":"2.0","error":{"code":-32600,"message":"RequestParam must be either array or object, got=String"},"id":null}"""

  test "unknown method is a method not found":
    let res = waitFor server.route(req("noSuchMethod", "[]"))
    check res == """{"jsonrpc":"2.0","error":{"code":-32601,"message":"'noSuchMethod' is not a registered RPC method"},"id":0}"""

  test "wrong parameter count is invalid params":
    let res = waitFor server.route(req("comboParams", "[1,2]"))
    check res == """{"jsonrpc":"2.0","error":{"code":-32602,"message":"`comboParams` raised an exception","data":"Expected 3 JSON parameter(s) but got 2"},"id":0}"""

  test "wrong parameter type is invalid params":
    let res = waitFor server.route(req("comboParams", """[1,2,"three"]"""))
    check res == """{"jsonrpc":"2.0","error":{"code":-32602,"message":"`comboParams` raised an exception","data":"Parameter [c] of type 'int' could not be decoded: number expected"},"id":0}"""

  test "handler exception is a server error":
    let res = waitFor server.route(req("rpcCtxSyncWithRaises", """{"s":"foo"}"""))
    check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`rpcCtxSyncWithRaises` raised an exception","data":"err"},"id":0}"""

  test "notifications get no response, valid or not":
    # https://www.jsonrpc.org/specification#notification
    # "The Server MUST NOT reply to a Notification, including those that are
    # within a batch request", so the client is never made aware of errors
    block:
      let res = waitFor server.route(notif("noParams", "[]"))
      check res == ""
    block:
      # method not found
      let res = waitFor server.route(notif("noSuchMethod", "[]"))
      check res == ""
    block:
      # wrong number of parameters
      let res = waitFor server.route(notif("comboParams", "[1,2]"))
      check res == ""
    block:
      # wrong parameter type
      let res = waitFor server.route(notif("comboParams", """[1,2,"three"]"""))
      check res == ""
    block:
      # the handler raises
      let res = waitFor server.route(notif("rpcCtxSyncWithRaises", """{"s":"foo"}"""))
      check res == ""
    block:
      # within a batch, only the call is answered
      let res = waitFor server.route(
        "[" & notif("comboParams", "[1,2]") & "," & req("comboParams", "[1,2,3]") & "]")
      check res == """[{"jsonrpc":"2.0","result":6,"id":0}]"""

suite "rpc context":
  test "Rpc method async":
    let n = req("rpcCtxAsync", """{"s": "foo"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"ret1 foo","id":0}"""

  test "Rpc method async with no raises":
    let n = req("rpcCtxAsyncNoRaises", """{"s": "bar"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"ret2 bar","id":0}"""

  test "Rpc async raises listed exception":
    let n = req("rpcCtxAsyncWithRaises", """{"s": "err"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`rpcCtxAsyncWithRaises` raised an exception","data":"err"},"id":0}"""

  test "Rpc method sync":
    let n = req("rpcCtxSync", """{"s": "baz"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"ret3 baz","id":0}"""

  test "Rpc method sync with no raises":
    let n = req("rpcCtxSyncNoRaises", """{"s": "quz"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":"ret4 quz","id":0}"""

  test "Rpc sync raises listed exception":
    let n = req("rpcCtxSyncWithRaises", """{"s": "err"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`rpcCtxSyncWithRaises` raised an exception","data":"err"},"id":0}"""

  test "Rpc async raises unlisted exception should not compile":
    template ctxWithRaises(): untyped =
      server.rpc(JrpcConv):
        proc rpcCtxWithRaises(s: string): string {.async: (raises: []).} =
          raise (ref ValueError)(msg: "err")

    check not compiles(ctxWithRaises())

  test "Rpc sync raises unlisted exception should not compile":
    template ctxWithRaises(): untyped =
      server.rpc(JrpcConv):
        proc rpcCtxWithRaises(s: string): string {.raises: [].} =
          raise (ref ValueError)(msg: "err")

    check not compiles(ctxWithRaises())

  test "Rpc sync with inner await should not compile":
    template ctxWithAwait(): untyped =
      server.rpc(JrpcConv):
        proc rpcCtxSyncAwait(s: string): string =
          await noCancel sleepAsync(0)
          return "ret1 " & s

    check not compiles(ctxWithAwait())

  test "Rpc async empty response":
    let n = req("rpcCtxAsyncEmpty", """{"result": "foo"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":null,"id":0}"""

  test "Rpc sync empty response":
    let n = req("rpcCtxSyncEmpty", """{"result": "foo"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","result":null,"id":0}"""

  test "Empty error message":
    let res = waitFor server.route(req("emptyErrorMsg", "{}"))
    check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`emptyErrorMsg` raised an exception","data":""},"id":0}"""
