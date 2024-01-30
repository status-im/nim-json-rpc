# json-rpc
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  macros,
  ./shared_wrapper,
  ./jrpc_sys

{.push gcsafe, raises: [].}

proc createRpcProc(procName, parameters, callBody: NimNode): NimNode =
  # parameters come as a tree
  var paramList = newSeq[NimNode]()
  for p in parameters: paramList.add(p)

  let body = quote do:
    {.gcsafe.}:
      `callBody`

  # build proc
  result = newProc(procName, paramList, body)

  # make proc async
  result.addPragma ident"async"
  result.addPragma ident"gcsafe"
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
    # temporary variable to hold `Response` from rpc call
    rpcResult = ident "res"
    # proc return variable
    procRes = ident"result"
    doDecode = quote do:
      `procRes` = decode(JrpcConv, `rpcResult`.string, typeof `returnType`)
    maybeWrap =
      if returnType.noWrap: quote do:
        `procRes` = `rpcResult`
      else: doDecode
      
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

    # `rpcResult` is of type `JsonString`
    let `rpcResult` = await `clientIdent`.call(`pathStr`, `reqParams`)
    `maybeWrap`


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
