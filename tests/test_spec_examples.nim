# json-rpc
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2,
  ../json_rpc/router,
  ./private/helpers

var server = RpcRouter()

server.rpc("subtract") do(minuend, subtrahend: int) -> int:
  return minuend - subtrahend

server.rpc("sum") do(a, b, c: int) -> int:
  return a + b + c

server.rpc("get_data") do() -> JsonString:
  return JsonString("""["hello",5]""")

server.rpc("update") do(a, b, c, d, e: int) -> void:
  discard

server.rpc("notify_hello") do(a: int) -> void:
  discard

server.rpc("notify_sum") do(a, b, c: int) -> void:
  discard

suite "json-rpc 2.0 spec examples":
  template checkResponse(req, resp: string): untyped =
    let res = waitFor server.route(req)
    check res == resp

  test "rpc call with positional parameters":
    block:
      # --> {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
      # <-- {"jsonrpc": "2.0", "result": 19, "id": 1}
      const req = """{"jsonrpc":"2.0","method":"subtract","params":[42, 23],"id": 1}"""
      const res = """{"jsonrpc":"2.0","result":19,"id":1}"""
      checkResponse(req, res)

    block:
      # --> {"jsonrpc": "2.0", "method": "subtract", "params": [23, 42], "id": 2}
      # <-- {"jsonrpc": "2.0", "result": -19, "id": 2}
      const req = """{"jsonrpc":"2.0","method":"subtract","params":[23, 42],"id": 2}"""
      const res = """{"jsonrpc":"2.0","result":-19,"id":2}"""
      checkResponse(req, res)

  test "rpc call with named parameters":
    block:
      # --> {"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23, "minuend": 42}, "id": 3}
      # <-- {"jsonrpc": "2.0", "result": 19, "id": 3}
      const req = """{"jsonrpc":"2.0","method":"subtract","params":{"subtrahend":23,"minuend":42},"id": 3}"""
      const res = """{"jsonrpc":"2.0","result":19,"id":3}"""
      checkResponse(req, res)

    block:
      # --> {"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23}, "id": 4}
      # <-- {"jsonrpc": "2.0", "result": 19, "id": 4}
      const req = """{"jsonrpc":"2.0","method":"subtract","params":{"minuend":42,"subtrahend":23},"id":4}"""
      const res = """{"jsonrpc":"2.0","result":19,"id":4}"""
      checkResponse(req, res)

  test "a Notification":
    block:
      # --> {"jsonrpc": "2.0", "method": "update", "params": [1,2,3,4,5]}
      const req = """{"jsonrpc":"2.0","method":"update","params":[1,2,3,4,5]}"""
      checkResponse(req, "")
    block:
      # --> {"jsonrpc": "2.0", "method": "foobar"}
      # not registered, but a notification is never answered
      const req = """{"jsonrpc":"2.0","method":"foobar"}"""
      checkResponse(req, "")

  test "rpc call of non-existent method":
    # --> {"jsonrpc": "2.0", "method": "foobar", "id": "1"}
    # <-- {"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": "1"}
    const req = """{"jsonrpc":"2.0","method":"foobar","id":"1"}"""
    const res = """{"jsonrpc":"2.0","error":{"code":-32601,"message":"'foobar' is not a registered RPC method"},"id":"1"}"""
    checkResponse(req, res)

  test "rpc call with invalid JSON":
    # --> {"jsonrpc": "2.0", "method": "foobar, "params": "bar", "baz]
    # <-- {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": null}
    const req = """{"jsonrpc":"2.0","method":"foobar,"params":"bar","baz]"""
    const res = """{"jsonrpc":"2.0","error":{"code":-32700,"message":"string expected"},"id":null}"""
    checkResponse(req, res)

  # XXX wrong result
  # https://github.com/status-im/nim-json-serialization/issues/149
  test "rpc call with invalid Request object":
    # --> {"jsonrpc": "2.0", "method": 1, "params": "bar"}
    # <-- {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null}
    const req = """{"jsonrpc": "2.0", "method": 1, "params": "bar"}"""
    const res = """{"jsonrpc":"2.0","error":{"code":-32700,"message":"string expected"},"id":null}"""
    checkResponse(req, res)

  test "rpc call Batch, invalid JSON":
    # --> [{"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"}, {"jsonrpc": "2.0", "method"]
    # <-- {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": null}
    const req = """[{"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},{"jsonrpc": "2.0", "method"]"""
    const res = """{"jsonrpc":"2.0","error":{"code":-32700,"message":"':' expected"},"id":null}"""
    checkResponse(req, res)

  test "rpc call with an empty Array":
    # --> []
    # <-- {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null}
    const req = """[]"""
    const res = """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Batch must contain at least one message"},"id":null}"""
    checkResponse(req, res)

  # XXX wrong result
  test "rpc call with an invalid Batch (but not empty)":
    # --> [1]
    # <-- [{"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null}]
    const req = """[1]"""
    const res = """{"jsonrpc":"2.0","error":{"code":-32700,"message":"'{' expected"},"id":null}"""
    checkResponse(req, res)

  # XXX wrong result
  test "rpc call with invalid Batch":
    # --> [1,2,3]
    # <-- [{"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null},
    #      {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null},
    #      {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null}]
    const req = """[1,2,3]"""
    const res = """{"jsonrpc":"2.0","error":{"code":-32700,"message":"'{' expected"},"id":null}"""
    checkResponse(req, res)

  # XXX wrong result
  test "rpc call Batch":
    # --> [{"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
    #      {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]},
    #      {"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},
    #      {"foo": "boo"},
    #      {"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},
    #      {"jsonrpc": "2.0", "method": "get_data", "id": "9"}]
    # <-- [{"jsonrpc": "2.0", "result": 7, "id": "1"},
    #      {"jsonrpc": "2.0", "result": 19, "id": "2"},
    #      {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null},
    #      {"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": "5"},
    #      {"jsonrpc": "2.0", "result": ["hello", 5], "id": "9"}]
    const req =
      """[{"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},""" &
      """{"jsonrpc": "2.0", "method": "notify_hello", "params": [7]},""" &
      """{"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},""" &
      """{"foo": "boo"},""" &
      """{"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},""" &
      """{"jsonrpc": "2.0", "method": "get_data", "id": "9"}]"""
    const res = """{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":null}"""
    checkResponse(req, res)

  test "rpc call Batch, all valid":
    # the same batch without the invalid element, to show the rest is conformant
    const req =
      """[{"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},""" &
      """{"jsonrpc": "2.0", "method": "notify_hello", "params": [7]},""" &
      """{"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},""" &
      """{"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},""" &
      """{"jsonrpc": "2.0", "method": "get_data", "id": "9"}]"""
    const res =
      """[{"jsonrpc":"2.0","result":7,"id":"1"},""" &
      """{"jsonrpc":"2.0","result":19,"id":"2"},""" &
      """{"jsonrpc":"2.0","error":{"code":-32601,"message":"'foo.get' is not a registered RPC method"},"id":"5"},""" &
      """{"jsonrpc":"2.0","result":["hello",5],"id":"9"}]"""
    checkResponse(req, res)

  test "rpc call Batch (all notifications)":
    # --> [{"jsonrpc": "2.0", "method": "notify_sum", "params": [1,2,4]},
    #      {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}]
    # <-- nothing is returned for all notification batches
    const req =
      """[{"jsonrpc": "2.0", "method": "notify_sum", "params": [1,2,4]},""" &
      """{"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}]"""
    checkResponse(req, "")
