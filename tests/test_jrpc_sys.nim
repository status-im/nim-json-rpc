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
  ../json_rpc/private/jrpc_sys

func id(): RequestId =
  RequestId(kind: riNull)

func id(x: string): RequestId =
  RequestId(kind: riString, str: x)

func id(x: int): RequestId =
  RequestId(kind: riNumber, num: x)

func req(id: int or string, meth: string, params: RequestParamsTx): RequestTx =
  RequestTx(
    id: Opt.some(id(id)),
    `method`: meth,
    params: params
  )

func reqNull(meth: string, params: RequestParamsTx): RequestTx =
  RequestTx(
    id: Opt.some(id()),
    `method`: meth,
    params: params
  )

func reqNoId(meth: string, params: RequestParamsTx): RequestTx =
  RequestTx(
    `method`: meth,
    params: params
  )

func toParams(params: varargs[(string, JsonString)]): seq[ParamDescNamed] =
  for x in params:
    result.add ParamDescNamed(name:x[0], value:x[1])

func namedPar(params: varargs[(string, JsonString)]): RequestParamsTx =
  RequestParamsTx(
    kind: rpNamed,
    named: toParams(params)
  )

func posPar(params: varargs[JsonString]): RequestParamsTx =
  RequestParamsTx(
    kind: rpPositional,
    positional: @params
  )

func res(id: int or string, r: JsonString): ResponseTx =
  ResponseTx(
    id: id(id),
    kind: rkResult,
    result: r,
  )

func res(id: int or string, err: ResponseError): ResponseTx =
  ResponseTx(
    id: id(id),
    kind: rkError,
    error: err,
  )

func resErr(code: int, msg: string): ResponseError =
  ResponseError(
    code: code,
    message: msg,
  )

func resErr(code: int, msg: string, data: JsonString): ResponseError =
  ResponseError(
    code: code,
    message: msg,
    data: Opt.some(data)
  )

func reqBatch(args: varargs[RequestTx]): RequestBatchTx =
  if args.len == 1:
    RequestBatchTx(
      kind: rbkSingle, single: args[0]
    )
  else:
    RequestBatchTx(
      kind: rbkMany, many: @args
    )

func resBatch(args: varargs[ResponseTx]): ResponseBatchTx =
  if args.len == 1:
    ResponseBatchTx(
      kind: rbkSingle, single: args[0]
    )
  else:
    ResponseBatchTx(
      kind: rbkMany, many: @args
    )

suite "jrpc_sys conversion":
  let np1 = namedPar(("banana", JsonString("true")), ("apple", JsonString("123")))
  let pp1 = posPar(JsonString("123"), JsonString("true"), JsonString("\"hello\""))

  test "RequestTx -> RequestRx: id(int), positional":
    let tx = req(123, "int_positional", pp1)
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, RequestRx)

    check:
      rx.jsonrpc.isSome
      rx.id.kind == riNumber
      rx.id.num == 123
      rx.meth.get == "int_positional"
      rx.params.kind == rpPositional
      rx.params.positional.len == 3
      rx.params.positional[0].kind == JsonValueKind.Number
      rx.params.positional[1].kind == JsonValueKind.Bool
      rx.params.positional[2].kind == JsonValueKind.String

  test "RequestTx -> RequestRx: id(string), named":
    let tx = req("word", "string_named", np1)
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, RequestRx)

    check:
      rx.jsonrpc.isSome
      rx.id.kind == riString
      rx.id.str == "word"
      rx.meth.get == "string_named"
      rx.params.kind == rpNamed
      rx.params.named[0].name == "banana"
      rx.params.named[0].value.string == "true"
      rx.params.named[1].name == "apple"
      rx.params.named[1].value.string == "123"

  test "RequestTx -> RequestRx: id(null), named":
    let tx = reqNull("null_named", np1)
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, RequestRx)

    check:
      rx.jsonrpc.isSome
      rx.id.kind == riNull
      rx.meth.get == "null_named"
      rx.params.kind == rpNamed
      rx.params.named[0].name == "banana"
      rx.params.named[0].value.string == "true"
      rx.params.named[1].name == "apple"
      rx.params.named[1].value.string == "123"

  test "RequestTx -> RequestRx: none, none":
    let tx = reqNoId("none_positional", posPar())
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, RequestRx)

    check:
      rx.jsonrpc.isSome
      rx.id.kind == riNull
      rx.meth.get == "none_positional"
      rx.params.kind == rpPositional
      rx.params.positional.len == 0

  test "ResponseTx -> ResponseRx: id(int), res":
    let tx = res(777, JsonString("true"))
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, ResponseRx)
    check:
      rx.id.num == 777
      rx.kind == ResponseKind.rkResult
      rx.result.string.len > 0
      rx.result == JsonString("true")

  test "ResponseTx -> ResponseRx: id(string), err: nodata":
    let tx = res("gum", resErr(999, "fatal"))
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, ResponseRx)
    check:
      rx.id.str == "gum"
      rx.kind == ResponseKind.rkError
      rx.error.code == 999
      rx.error.message == "fatal"
      rx.error.data.isNone

  test "ResponseTx -> ResponseRx: id(string), err: some data":
    let tx = res("gum", resErr(999, "fatal", JsonString("888.999")))
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, ResponseRx)
    check:
      rx.id.str == "gum"
      rx.kind == ResponseKind.rkError
      rx.error.code == 999
      rx.error.message == "fatal"
      rx.error.data.get == JsonString("888.999")

  test "RequestBatchTx -> RequestBatchRx: single":
    let tx1 = req(123, "int_positional", pp1)
    let tx = reqBatch(tx1)
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, RequestBatchRx)
    check:
      rx.kind == rbkSingle

  test "RequestBatchTx -> RequestBatchRx: many":
    let tx1 = req(123, "int_positional", pp1)
    let tx2 = req("word", "string_named", np1)
    let tx3 = reqNull("null_named", np1)
    let tx4 = reqNoId("none_positional", posPar())
    let tx = reqBatch(tx1, tx2, tx3, tx4)
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, RequestBatchRx)
    check:
      rx.kind == rbkMany
      rx.many.len == 4

  test "ResponseBatchTx -> ResponseBatchRx: single":
    let tx1 = res(777, JsonString("true"))
    let tx = resBatch(tx1)
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, ResponseBatchRx)
    check:
      rx.kind == rbkSingle

  test "ResponseBatchTx -> ResponseBatchRx: many":
    let tx1 = res(777, JsonString("true"))
    let tx2 = res("gum", resErr(999, "fatal"))
    let tx3 = res("gum", resErr(999, "fatal", JsonString("888.999")))
    let tx = resBatch(tx1, tx2, tx3)
    let txBytes = JrpcSys.encode(tx)
    let rx = JrpcSys.decode(txBytes, ResponseBatchRx)
    check:
      rx.kind == rbkMany
      rx.many.len == 3

  test "skip null value":
    let jsonBytes = """{"jsonrpc":null, "id":null, "method":null, "params":null}"""
    let x = JrpcSys.decode(jsonBytes, RequestRx)
    check:
      x.jsonrpc.isNone
      x.id.kind == riNull
      x.`method`.isNone
      x.params.kind == rpPositional
