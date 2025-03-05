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
  macros,
  ./shared_wrapper,
  ./jrpc_sys

proc createRpcProc(procName, parameters, callBody: NimNode): NimNode =
  # parameters come as a tree
  var paramList = newSeq[NimNode]()
  for p in parameters: paramList.add(p)

  # build proc
  result = newProc(procName, paramList, callBody)

  # make proc async
  result.addPragma ident"async"
  # export this proc
  result[0] = nnkPostfix.newTree(ident"*", newIdentNode($procName))

proc createBatchCallProc(procName, parameters, callBody: NimNode): NimNode =
  # parameters come as a tree
  var paramList = newSeq[NimNode]()
  for p in parameters: paramList.add(p)

  # build proc
  result = newProc(procName, paramList, callBody)

  # export this proc
  result[0] = nnkPostfix.newTree(ident"*", newIdentNode($procName))

proc setupConversion(reqParams, params: NimNode): NimNode =
  # populate json params
  # even rpcs with no parameters have an empty json array node sent

  params.expectKind nnkFormalParams
  result = newStmtList()
  result.add quote do:
    var `reqParams` = RequestParamsTx(kind: rpPositional)

  for parName, parType in paramsIter(params):
    result.add quote do:
      `reqParams`.positional.add encode(JrpcConv, `parName`).JsonString

template maybeUnwrapClientResult*(client, meth, reqParams, returnType): auto =
  ## Don't decode e.g. JsonString, return as is
  when noWrap(typeof returnType):
    await client.call(meth, reqParams)
  else:
    let res = await client.call(meth, reqParams)
    decode(JrpcConv, res.string, typeof returnType)

proc createRpcFromSig*(clientType, rpcDecl: NimNode, alias = NimNode(nil)): NimNode =
  ## This procedure will generate something like this:
  ## - Currently it always send positional parameters to the server
  ##
  ## proc rpcApi(client: RpcClient; paramA: TypeA; paramB: TypeB): Future[RetType] =
  ##   {.gcsafe.}:
  ##     var reqParams = RequestParamsTx(kind: rpPositional)
  ##     reqParams.positional.add encode(JrpcConv, paramA).JsonString
  ##     reqParams.positional.add encode(JrpcConv, paramB).JsonString
  ##     let res = await client.call("rpcApi", reqParams)
  ##     result = decode(JrpcConv, res.string, typeof RetType)
  ##
  ## 2nd version to handle batch request after calling client.prepareBatch()
  ## proc rpcApi(batch: RpcBatchCallRef; paramA: TypeA; paramB: TypeB) =
  ##   var reqParams = RequestParamsTx(kind: rpPositional)
  ##   reqParams.positional.add encode(JrpcConv, paramA).JsonString
  ##   reqParams.positional.add encode(JrpcConv, paramB).JsonString
  ##   batch.batch.add RpcBatchItem(meth: "rpcApi", params: reqParams)

  # Each input parameter in the rpc signature is converted
  # to json using JrpcConv.encode.
  # Return types are then converted back to native Nim types.

  let
    params = rpcDecl.findChild(it.kind == nnkFormalParams).ensureReturnType
    procName = if alias.isNil: rpcDecl.name else: alias
    pathStr = $rpcDecl.name
    returnType = params[0]
    reqParams = ident "reqParams"
    setup = setupConversion(reqParams, params)
    clientIdent = ident"client"
    batchParams = params.copy
    batchIdent = ident "batch"

  # insert rpc client as first parameter
  params.insert(1, nnkIdentDefs.newTree(
    clientIdent,
    ident($clientType),
    newEmptyNode()
  ))

  # convert return type to Future
  params[0] = nnkBracketExpr.newTree(ident"Future", returnType)

  # perform rpc call
  let callBody = quote do:
    # populate request params
    `setup`
    maybeUnwrapClientResult(`clientIdent`, `pathStr`, `reqParams`, `returnType`)

  # insert RpcBatchCallRef as first parameter
  batchParams.insert(1, nnkIdentDefs.newTree(
    batchIdent,
    ident "RpcBatchCallRef",
    newEmptyNode()
  ))

  # remove return type
  batchParams[0] = newEmptyNode()

  let batchCallBody = quote do:
    `setup`
    `batchIdent`.batch.add RpcBatchItem(
      meth: `pathStr`,
      params: `reqParams`
    )

  # create rpc proc
  result = newStmtList()
  result.add createRpcProc(procName, params, callBody)
  result.add createBatchCallProc(procName, batchParams, batchCallBody)

  when defined(nimDumpRpcs):
    echo pathStr, ":\n", result.repr

proc processRpcSigs*(clientType, parsedCode: NimNode): NimNode =
  result = newStmtList()

  for line in parsedCode:
    if line.kind == nnkProcDef:
      var procDef = createRpcFromSig(clientType, line)
      result.add(procDef)

proc cresteSignaturesFromString*(clientType: NimNode, sigStrings: string): NimNode =
  try:
    result = processRpcSigs(clientType, sigStrings.parseStmt())
  except ValueError as exc:
    doAssert(false, exc.msg)

{.pop.}
