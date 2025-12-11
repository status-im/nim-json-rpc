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
      check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`std_option` raised an exception","data":"Parameter [D] of type 'Option[system.int]' could not be decoded: number expected"},"id":0}"""
    elif meth == "results_opt":
      check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`results_opt` raised an exception","data":"Parameter [D] of type 'Opt[system.int]' could not be decoded: number expected"},"id":0}"""
    elif meth == "mixed_opt":
      check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`mixed_opt` raised an exception","data":"Parameter [D] of type 'Option[system.int]' could not be decoded: number expected"},"id":0}"""
    else:
      check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`alias_opt` raised an exception","data":"Parameter [D] of type 'Option[system.int]' could not be decoded: number expected"},"id":0}"""

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
    check res == """{"jsonrpc":"2.0","error":{"code":-32000,"message":"`noParams` raised an exception","data":"Expected 0 JSON parameter(s) but got 1"},"id":0}"""

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
