# json-rpc
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[json, macros],
  ./jrpc_sys,
  ../jsonmarshal

iterator paramsIter*(params: NimNode): tuple[ident, str, ntype: NimNode] =
  ## Forward iterator of handler parameters
  for i in 1 ..< params.len:
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len-2:
      let
        paramIdent = arg[j].basename
        paramStr =
          if arg[j].kind == nnkPragmaExpr:
            var paramStr: NimNode
            for e in arg[j][1]:
              if e[0].eqIdent("serializedFieldName"):
                paramStr = e[1]
                break
            if paramStr == nil:
              paramStr = newLit($paramIdent)
            paramStr
          else:
            newLit($paramIdent)
      yield (paramIdent, paramStr, argType)

func ensureReturnType*(params: NimNode): NimNode =
  let retType = ident"JsonNode"
  if params.isNil or params.kind == nnkEmpty or params.len == 0:
    return nnkFormalParams.newTree(retType)

  if params.len >= 1 and params[0].kind == nnkEmpty:
    params[0] = retType

  params

template noWrap*(returnType: type): auto =
  ## Condition when return type should not be encoded
  ## to Json
  returnType is JsonString or returnType is void

func paramsTx*(params: JsonNode, Format: type SerializationFormat): RequestParamsTx =
  if params.kind == JArray:
    var args: seq[JsonString]
    for x in params:
      args.add encode(Format, x).JsonString
    RequestParamsTx(
      kind: rpPositional,
      positional: system.move(args),
    )
  elif params.kind == JObject:
    var args: seq[ParamDescNamed]
    for k, v in params:
      args.add ParamDescNamed(
        name: k,
        value: encode(Format, v).JsonString,
      )
    RequestParamsTx(
      kind: rpNamed,
      named: system.move(args),
    )
  else:
    RequestParamsTx(
      kind: rpPositional,
      positional: @[encode(Format, params).JsonString],
    )

func paramsTx*(params: JsonNode): RequestParamsTx =
  paramsTx(params, JrpcConv)

func requestTx*(name: string, params: sink RequestParamsTx, id: int): RequestTx =
  RequestTx(
    id: Opt.some(RequestId(kind: riNumber, num: id)),
    `method`: name,
    params: params,
  )
