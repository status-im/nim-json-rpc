# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[json, tables, macros],
  chronicles,
  chronos,
  results,
  ./jsonmarshal,
  ./private/jrpc_sys,
  ./private/client_handler_wrapper,
  ./private/shared_wrapper,
  ./errors

from strutils import replace

export
  chronos,
  tables,
  jsonmarshal,
  RequestParamsTx,
  RequestBatchTx,
  ResponseBatchRx,
  results

const MaxMessageBodyBytes* = 128 * 1024 * 1024  # 128 MB (JSON encoded)

type
  RpcBatchItem* = object
    meth*: string
    params*: RequestParamsTx

  RpcBatchCallRef* = ref object of RootRef
    client*: RpcClient
    batch*: seq[RpcBatchItem]

  RpcBatchResponse* = object
    error*: Opt[string]
    result*: JsonString

  RpcClient* = ref object of RootRef
    awaiting*: Table[RequestId, Future[JsonString]]
    lastId: int
    onDisconnect*: proc() {.gcsafe, raises: [].}
    onProcessMessage*: proc(client: RpcClient, line: string):
      Result[bool, string] {.gcsafe, raises: [].}
    batchFut*: Future[ResponseBatchRx]

  GetJsonRpcRequestHeaders* = proc(): seq[(string, string)] {.gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func validateResponse(resIndex: int, res: ResponseRx): Result[void, string] =
  if res.jsonrpc.isNone:
    return err("missing or invalid `jsonrpc` in response " & $resIndex)

  if res.id.isNone:
    if res.error.isSome:
      let error = JrpcSys.encode(res.error.get)
      return err(error)
    else:
      return err("missing or invalid response id in response " & $resIndex)

  if res.error.isSome:
    let error = JrpcSys.encode(res.error.get)
    return err(error)

  # Up to this point, the result should contains something
  if res.result.string.len == 0:
    return err("missing or invalid response result in response " & $resIndex)

  ok()

proc processResponse(resIndex: int,
                     map: var Table[RequestId, int],
                     responses: var seq[RpcBatchResponse],
                     response: ResponseRx): Result[void, string] =
  let r = validateResponse(resIndex, response)
  if r.isErr:
    if response.id.isSome:
      let id = response.id.get
      var index: int
      if not map.pop(id, index):
        return err("cannot find message id: " & $id & " in response " & $resIndex)
      responses[index] = RpcBatchResponse(
        error: Opt.some(r.error)
      )
    else:
      return err(r.error)
  else:
    let id = response.id.get
    var index: int
    if not map.pop(id, index):
      return err("cannot find message id: " & $id & " in response " & $resIndex)
    responses[index] = RpcBatchResponse(
      result:  response.result
    )

  ok()

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func requestTxEncode*(name: string, params: RequestParamsTx, id: RequestId): string =
  let req = requestTx(name, params, id)
  JrpcSys.encode(req)

func requestBatchEncode*(calls: RequestBatchTx): string =
  JrpcSys.encode(calls)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getNextId*(client: RpcClient): RequestId =
  client.lastId += 1
  RequestId(kind: riNumber, num: client.lastId)

method call*(client: RpcClient, name: string,
             params: RequestParamsTx): Future[JsonString]
                {.base, async.} =
  raiseAssert("`RpcClient.call` not implemented")

proc call*(client: RpcClient, name: string,
             params: JsonNode): Future[JsonString]
               {.async: (raw: true).} =
  client.call(name, params.paramsTx)

method close*(client: RpcClient): Future[void] {.base, async.} =
  raiseAssert("`RpcClient.close` not implemented")

method callBatch*(client: RpcClient,
                  calls: RequestBatchTx): Future[ResponseBatchRx]
                    {.base, async.} =
  raiseAssert("`RpcClient.callBatch` not implemented")

proc processMessage*(client: RpcClient, line: string): Result[void, string] =
  if client.onProcessMessage.isNil.not:
    let fallBack = client.onProcessMessage(client, line).valueOr:
      return err(error)
    if not fallBack:
      return ok()

  # Note: this doesn't use any transport code so doesn't need to be
  # differentiated.
  try:
    let batch = JrpcSys.decode(line, ResponseBatchRx)
    if batch.kind == rbkMany:
      if client.batchFut.isNil or client.batchFut.finished():
        client.batchFut = newFuture[ResponseBatchRx]()
      client.batchFut.complete(batch)
      return ok()

    let response = batch.single
    if response.jsonrpc.isNone:
      return err("missing or invalid `jsonrpc`")

    if response.id.isNone:
      if response.error.isSome:
        let error = JrpcSys.encode(response.error.get)
        return err(error)
      else:
        return err("missing or invalid response id")

    var requestFut: Future[JsonString]
    let id = response.id.get
    if not client.awaiting.pop(id, requestFut):
      return err("Cannot find message id \"" & $id & "\"")

    if response.error.isSome:
      let error = JrpcSys.encode(response.error.get)
      requestFut.fail(newException(JsonRpcError, error))
      return ok()

    # Up to this point, the result should contains something
    if response.result.string.len == 0:
      let msg = "missing or invalid response result"
      requestFut.fail(newException(JsonRpcError, msg))
      return ok()

    debug "Received JSON-RPC response",
      len = string(response.result).len, id = response.id
    requestFut.complete(response.result)
    return ok()

  except CatchableError as exc:
    return err(exc.msg)

proc prepareBatch*(client: RpcClient): RpcBatchCallRef =
  RpcBatchCallRef(client: client)

proc send*(batch: RpcBatchCallRef):
            Future[Result[seq[RpcBatchResponse], string]] {.
              async: (raises: []).} =
  var
    calls = RequestBatchTx(
      kind: rbkMany,
      many: newSeqOfCap[RequestTx](batch.batch.len),
    )
    responses = newSeq[RpcBatchResponse](batch.batch.len)
    map = initTable[RequestId, int]()

  for item in batch.batch:
    let id = batch.client.getNextId()
    map[id] = calls.many.len
    calls.many.add requestTx(item.meth, item.params, id)

  try:
    let res = await batch.client.callBatch(calls)
    if res.kind == rbkSingle:
      let r = processResponse(0, map, responses, res.single)
      if r.isErr:
        return err(r.error)
    else:
      for i, z in res.many:
        let r = processResponse(i, map, responses, z)
        if r.isErr:
          return err(r.error)
  except CatchableError as exc:
    return err(exc.msg)

  return ok(responses)

# ------------------------------------------------------------------------------
# Signature processing
# ------------------------------------------------------------------------------

macro createRpcSigs*(clientType: untyped, filePath: static[string]): untyped =
  ## Takes a file of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  cresteSignaturesFromString(clientType, staticRead($filePath.replace('\\', '/')))

macro createRpcSigsFromString*(clientType: untyped, sigString: static[string]): untyped =
  ## Takes a string of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  cresteSignaturesFromString(clientType, sigString)

macro createSingleRpcSig*(clientType: untyped, alias: static[string], procDecl: untyped): untyped =
  ## Takes a single forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  doAssert procDecl.len == 1, "Only accept single proc definition"
  let procDecl = procDecl[0]
  procDecl.expectKind nnkProcDef
  result = createRpcFromSig(clientType, procDecl, ident(alias))

macro createRpcSigsFromNim*(clientType: untyped, procList: untyped): untyped =
  ## Takes a list of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  processRpcSigs(clientType, procList)

{.pop.}
