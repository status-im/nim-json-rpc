# json-rpc
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, macros],
  ./jrpc_sys,
  ./jrpc_conv

iterator paramsIter*(params: NimNode): tuple[name, ntype: NimNode] =
  ## Forward iterator of handler parameters
  for i in 1 ..< params.len:
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len-2:
      yield (arg[j], argType)

func ensureReturnType*(params: NimNode): NimNode =
  let retType = ident"JsonNode"
  if params.isNil or params.kind == nnkEmpty or params.len == 0:
    return nnkFormalParams.newTree(retType)

  if params.len >= 1 and params[0].kind == nnkEmpty:
    params[0] = retType

  params

func noWrap*(returnType: NimNode): bool =
  ## Condition when return type should not be encoded
  ## to Json
  returnType.repr == "JsonString" or
    returnType.repr == "JsonString"

func paramsTx*(params: JsonNode): RequestParamsTx =
  if params.kind == JArray:
    var args: seq[JsonString]
    for x in params:
      args.add JrpcConv.encode(x).JsonString
    RequestParamsTx(
      kind: rpPositional,
      positional: system.move(args),
    )
  elif params.kind == JObject:
    var args: seq[ParamDescNamed]
    for k, v in params:
      args.add ParamDescNamed(
        name: k,
        value: JrpcConv.encode(v).JsonString,
      )
    RequestParamsTx(
      kind: rpNamed,
      named: system.move(args),
    )
  else:
    RequestParamsTx(
      kind: rpPositional,
      positional: @[JrpcConv.encode(params).JsonString],
    )

func requestTx*(name: string, params: RequestParamsTx, id: RequestId): RequestTx =
  RequestTx(
    id: Opt.some(id),
    `method`: name,
    params: params,
  )
