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
  json_serialization/std/options

var server = RpcRouter()

server.rpc("optional") do(A: int, B: Option[int], C: string, D: Option[int], E: Option[string]) -> string:
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

func req(meth: string, params: string): string =
  """{"jsonrpc":"2.0", "id":0, "method": """ &
    "\"" & meth & "\", \"params\": " & params & "}"

suite "rpc router":
  test "no params":
    let n = req("noParams", "[]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":123}"""

  test "no params with params":
    let n = req("noParams", "[123]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"error":{"code":-32000,"message":"noParams raised an exception","data":"Expected 0 Json parameter(s) but got 1"}}"""

  test "optional B E, positional":
    let n = req("optional", "[44, null, \"apple\", 33]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":"A: 44, B: 99, C: apple, D: 33, E: none"}"""

  test "optional B D E, positional":
    let n = req("optional", "[44, null, \"apple\"]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":"A: 44, B: 99, C: apple, D: 77, E: none"}"""

  test "optional D E, positional":
    let n = req("optional", "[44, 567, \"apple\"]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":"A: 44, B: 567, C: apple, D: 77, E: none"}"""

  test "optional D wrong E, positional":
    let n = req("optional", "[44, 567, \"apple\", \"banana\"]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"error":{"code":-32000,"message":"optional raised an exception","data":"Parameter [D] of type 'Option[system.int]' could not be decoded: number expected"}}"""

  test "optional D extra, positional":
    let n = req("optional", "[44, 567, \"apple\", 999, \"banana\", true]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":"A: 44, B: 567, C: apple, D: 999, E: banana"}"""

  test "optional B D E, named":
    let n = req("optional", """{"A": 33, "C":"banana" }""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":"A: 33, B: 99, C: banana, D: 77, E: none"}"""

  test "optional B E, D front, named":
    let n = req("optional", """{"D": 8887, "A": 33, "C":"banana" }""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":"A: 33, B: 99, C: banana, D: 8887, E: none"}"""

  test "optional B E, D front, extra X, named":
    let n = req("optional", """{"D": 8887, "X": false , "A": 33, "C":"banana"}""")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":"A: 33, B: 99, C: banana, D: 8887, E: none"}"""

  test "empty params":
    let n = req("emptyParams", "[]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":777}"""

  test "combo params":
    let n = req("comboParams", "[6,7,8]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":21}"""

  test "return json string":
    let n = req("returnJsonString", "[6,7,8]")
    let res = waitFor server.route(n)
    check res == """{"jsonrpc":"2.0","id":0,"result":21}"""
