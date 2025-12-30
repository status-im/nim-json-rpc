# json-rpc
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.

import unittest2, ../json_rpc/private/jrpc_sys

suite "jrpc_sys serialization":
  test "request: id":
    const cases = [
      (
        """{"jsonrpc":"2.0","method":"none"}""",
        RequestTx(`method`: "none", id: Opt.none(RequestId)),
      ),
      (
        """{"jsonrpc":"2.0","method":"null","id":null}""",
        RequestTx(`method`: "null", id: Opt.some(RequestId(kind: riNull))),
      ),
      (
        """{"jsonrpc":"2.0","method":"num","id":42}""",
        RequestTx(`method`: "num", id: Opt.some(RequestId(kind: riNumber, num: 42))),
      ),
      (
        """{"jsonrpc":"2.0","method":"str","id":"str"}""",
        RequestTx(`method`: "str", id: Opt.some(RequestId(kind: riString, str: "str"))),
      ),
    ]

    for (expected, tx) in cases:
      let
        encoded = JrpcSys.encode(tx)
        rx = JrpcSys.decode(expected, RequestRx2)
      checkpoint(expected)
      checkpoint(encoded)
      checkpoint($rx)
      check:
        encoded == expected
        tx.id == rx.id

  test "request: parameters":
    const cases = [
      (
        """{"jsonrpc":"2.0","method":"empty_positional"}""",
        RequestTx(
          `method`: "empty_positional",
          params: RequestParamsTx(kind: rpPositional, positional: @[]),
        ),
      ),
      (
        """{"jsonrpc":"2.0","method":"int_positional","params":[123,true,"hello"],"id":123}""",
        RequestTx(
          `method`: "int_positional",
          id: Opt.some(RequestId(kind: riNumber, num: 123)),
          params: RequestParamsTx(
            kind: rpPositional,
            positional:
              @[JsonString("123"), JsonString("true"), JsonString("\"hello\"")],
          ),
        ),
      ),
      (
        """{"jsonrpc":"2.0","method":"string_named","params":{"banana":true,"apple":123},"id":"word"}""",
        RequestTx(
          `method`: "string_named",
          id: Opt.some(RequestId(kind: riString, str: "word")),
          params: RequestParamsTx(
            kind: rpNamed,
            named:
              @[
                ParamDescNamed(name: "banana", value: JsonString("true")),
                ParamDescNamed(name: "apple", value: JsonString("123")),
              ],
          ),
        ),
      ),
    ]
    for (expected, tx) in cases:
      let
        encoded = JrpcSys.encode(tx)
        rx = JrpcSys.decode(encoded, RequestRx2)
      checkpoint(expected)
      checkpoint(encoded)
      checkpoint($rx)
      check:
        encoded == expected
        tx.params.kind == rx.params.kind
      if tx.params.kind == rpPositional:
        let
          tpos = tx.params.positional
          rpos = rx.params.positional
        check:
          tpos.len == rpos.len
        for i in 0 ..< tpos.len:
          check tpos[i] == rpos[i].param
      elif tx.params.kind == rpNamed:
        let
          tnamed = tx.params.named
          rnamed = rx.params.named
        check:
          tnamed.len == rnamed.len
        for i in 0 ..< tnamed.len:
          check:
            tnamed[i].name == rnamed[i].name
            tnamed[i].value == rnamed[i].value

  test "response: result and error encodings":
    const cases = [
      (
        """{"jsonrpc":"2.0","result":true,"id":null}""",
        ResponseTx(kind: rkResult, result: JsonString("true")),
      ),
      (
        """{"jsonrpc":"2.0","error":{"code":999,"message":"fatal"},"id":null}""",
        ResponseTx(kind: rkError, error: ResponseError(code: 999, message: "fatal")),
      ),
    ]
    for (expected, tx) in cases:
      let
        encoded = JrpcSys.encode(tx)
        rx = JrpcSys.decode(encoded, ResponseRx2)
      checkpoint(expected)
      checkpoint(encoded)
      checkpoint($rx)
      check:
        encoded == expected
      if tx.kind == rkResult:
        check:
          rx.kind == ResponseKind.rkResult
          rx.id == tx.id
      else:
        check:
          rx.kind == ResponseKind.rkError
          rx.id == tx.id
          rx.error.code == tx.error.code
          rx.error.message == tx.error.message

  test "batch requests: single and many encodings":
    const cases = [
      (
        """{"jsonrpc":"2.0","method":"a"}""",
        RequestBatchRx(kind: rbkSingle, single: RequestRx2(`method`: "a")),
      ),
      (
        """[{"jsonrpc":"2.0","method":"a"},{"jsonrpc":"2.0","method":"b"}]""",
        RequestBatchRx(
          kind: rbkMany, many: @[RequestRx2(`method`: "a"), RequestRx2(`method`: "b")]
        ),
      ),
    ]
    for (expected, tx) in cases:
      let rx = JrpcSys.decode(expected, RequestBatchRx)
      checkpoint(expected)
      checkpoint($rx)
      if tx.kind == rbkSingle:
        check:
          rx.kind == rbkSingle
          rx.single.`method` == tx.single.`method`
      else:
        check:
          rx.kind == rbkMany
          rx.many.len == tx.many.len

  test "malformed JSON and top-level incorrect types are rejected":
    expect UnexpectedValueError:
      discard JrpcSys.decode("{ this is not valid json }", RequestRx2)
    expect UnexpectedValueError:
      discard JrpcSys.decode("123", RequestRx2)
    expect UnexpectedValueError:
      discard JrpcSys.decode("\"just a string\"", RequestRx2)

  test "invalid constructs: empty batch and mixed-type batch entries rejected":
    expect UnexpectedValueError:
      discard JrpcSys.decode("[]", RequestBatchRx)

    let mixed =
      """[{"jsonrpc":"2.0","method":"foo","params":[]},42,{"jsonrpc":"2.0","method":"notify_no_id","params":["a"]}]"""
    expect UnexpectedValueError:
      discard JrpcSys.decode(mixed, RequestBatchRx)

  test "invalid id types rejected":
    expect UnexpectedValueError:
      discard JrpcSys.decode("""{"jsonrpc":"2.0","id":{},"method":"m"}""", RequestRx2)
    expect UnexpectedValueError:
      discard
        JrpcSys.decode("""{"jsonrpc":"2.0","id":[1,2],"method":"m"}""", RequestRx2)

  test "error response preserves standard fields and encoder correctness":
    const cases = [
      (
        """{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":null}""",
        ResponseTx(
          kind: rkError, error: ResponseError(code: -32601, message: "Method not found")
        ),
      )
    ]
    for (expected, tx) in cases:
      let
        encoded = JrpcSys.encode(tx)
        rx = JrpcSys.decode(encoded, ResponseRx2)
      check:
        encoded == expected
        rx.kind == ResponseKind.rkError
        rx.error.code == tx.error.code
        rx.error.message == tx.error.message
