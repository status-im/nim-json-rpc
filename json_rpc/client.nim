# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import chronos/futures

# json_rpc seems to frequently trigger this bug so add a workaround here
when (NimMajor, NimMinor, NimPatch) < (2, 2, 6):
  proc json_rpc_workaround_24844_future_string*() {.exportc.} =
    # TODO https://github.com/nim-lang/Nim/issues/24844
    discard Future[string]().value()

import
  std/[deques, hashes, json, macros, tables],
  chronos,
  chronicles,
  stew/byteutils,
  results,
  ./private/[client_handler_wrapper, jrpc_sys, shared_wrapper],
  ./[errors, jsonmarshal, router]

from strutils import replace

export
  chronos, deques, tables, jsonmarshal, RequestParamsTx, RequestIdKind,
  RequestId, RequestTx, RequestParamKind, results

logScope:
  topics = "jsonrpc client"

const defaultMaxMessageSize* = 128 * 1024 * 1024  # 128 MB (JSON encoded)

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
    lastId: int
    onDisconnect*: proc() {.gcsafe, raises: [].}
    onProcessMessage* {.deprecated.}: proc(client: RpcClient, line: string):
      Result[bool, string] {.gcsafe, raises: [].}
    remote*: string
      # Client identifier, for logging
    maxMessageSize*: int

  RpcRouterCallback* =
    proc(request: RequestBatchRx): Future[seq[byte]] {.async: (raises: []).}

  ResponseFut* = Future[seq[byte]].Raising([CancelledError, JsonRpcError])
  RpcConnection* = ref object of RpcClient
    router*: RpcRouterCallback
      ## Router used for transports that support bidirectional communication
    pendingRequests*: Deque[ResponseFut]

  GetJsonRpcRequestHeaders* = proc(): seq[(string, string)] {.gcsafe, raises: [].}

func hash*(v: RpcClient): Hash =
  cast[Hash](addr v[])

func parseResponse(payload: openArray[byte], T: type): T {.raises: [JsonRpcError].} =
  try:
    JrpcSys.decode(payload, T)
  except SerializationError as exc:
    raise (ref InvalidResponse)(
      msg: exc.formatMsg("msg"), payload: @payload, parent: exc
    )

proc processsSingleResponse(
    response: sink ResponseRx2, id: int
): JsonString {.raises: [JsonRpcError].} =
  if response.id.kind != RequestIdKind.riNumber or response.id.num != id:
    raise
      (ref InvalidResponse)(msg: "Expected `id` " & $id & ", got " & $response.id)

  case response.kind
  of ResponseKind.rkError:
    raise (ref JsonRpcError)(msg: JrpcSys.encode(response.error))
  of ResponseKind.rkResult:
    move(response.result)

proc processsSingleResponse*(
    body: openArray[byte], id: int
): JsonString {.raises: [JsonRpcError].} =
  processsSingleResponse(parseResponse(body, ResponseRx2), id)

template withPendingFut*(client, fut, body: untyped): untyped =
  let fut = ResponseFut.init("jsonrpc.client.pending")
  client.pendingRequests.addLast fut
  body

method send(
    client: RpcClient, data: seq[byte]
) {.base, async: (raises: [CancelledError, JsonRpcError]).} =
  raiseAssert("`RpcClient.send` not implemented")

proc callOnProcessMessage*(
    client: RpcClient, line: openArray[byte]
): Result[bool, string] =
  if client.onProcessMessage.isNil.not:
    client.onProcessMessage(client, string.fromBytes(line))
  else:
    ok(true)

const defaultRouter = default(RpcRouter)

proc processMessage*(
    client: RpcConnection, line: seq[byte]
): Future[seq[byte]] {.async: (raises: [], raw: true).} =
  template makeResponse(res: seq[byte]): untyped =
    let ret = newFuture[seq[byte]]("processMessage")
    ret.complete(res)
    ret

  try:
    let request = JrpcSys.decode(line, RequestBatchRx)
    if client.router != nil:
      client.router(request)
    else:
      defaultRouter.route(request)
  except IncompleteObjectError:
    if client.pendingRequests.len() > 0:
      # Each response corresponds to one request - the caller might cancel
      # the future but we must still pop exactly one request per response since
      # we always send the request
      let fut = client.pendingRequests.popFirst()

      if not fut.finished():
        fut.complete(line)
      else:
        debug "Future already finished, dropping", state = fut.state()
    else:
      template shortLine(): string =
        if line.len > 64:
          string.fromBytes(line.toOpenArray(0, 64)) & "..."
        else:
          string.fromBytes(line)

      debug "Received message even though there's nothing queued, dropping",
        msg = shortLine()

    makeResponse(default(seq[byte]))
  except SerializationError as exc:
    makeResponse(wrapError(router.INVALID_REQUEST, exc.msg))

proc clearPending*(client: RpcConnection, exc: ref JsonRpcError) =
  while client.pendingRequests.len > 0:
    let fut = client.pendingRequests.popFirst()
    if not fut.finished():
      fut.fail(exc)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getNextId(client: RpcClient): int =
  client.lastId += 1
  client.lastId

method request(
    client: RpcClient, reqData: seq[byte]
): Future[seq[byte]] {.base, async: (raises: [CancelledError, JsonRpcError]).} =
  raiseAssert("`RpcClient.request` not implemented")

method close*(client: RpcClient): Future[void] {.base, async: (raises: []).} =
  raiseAssert("`RpcClient.close` not implemented")

proc notify*(
    client: RpcClient, name: string, params: RequestParamsTx
) {.async: (raises: [CancelledError, JsonRpcError], raw: true).} =
  ## Perform a "notification", ie a JSON-RPC request without response
  let requestData = JrpcSys.withWriter(writer):
    writer.writeNotification(name, params)

  debug "Sending JSON-RPC notification",
    name, len = requestData.len, remote = client.remote
  trace "Parameters", params

  # Release params memory earlier by using a raw proc for the initial
  # processing
  proc complete(
      client: RpcClient, request: auto
  ) {.async: (raises: [CancelledError, JsonRpcError]).} =
    try:
      await request
    except JsonRpcError as exc:
      debug "JSON-RPC notification failed", err = exc.msg, remote = client.remote
      raise exc

  let req = client.send(requestData)
  client.complete(req)

proc call*(
    client: RpcClient, name: string, params: RequestParamsTx
): Future[JsonString] {.async: (raises: [CancelledError, JsonRpcError], raw: true).} =
  ## Perform an RPC call returning the `result` of the call
  let
    # We don't really need an id since exchanges happen in order but using one
    # helps debugging, if nothing else
    id = client.getNextId()
    requestData = JrpcSys.withWriter(writer):
      writer.writeRequest(name, params, id)

  debug "Sending JSON-RPC request",
    name, len = requestData.len, id, remote = client.remote
  trace "Parameters", params

  # Release params memory earlier by using a raw proc for the initial
  # processing
  proc complete(
      client: RpcClient, request: auto, id: int
  ): Future[JsonString] {.async: (raises: [CancelledError, JsonRpcError]).} =
    try:
      let resData = await request

      debug "Processing JSON-RPC response",
        len = resData.len, id, remote = client.remote
      processsSingleResponse(resData, id)
    except JsonRpcError as exc:
      debug "JSON-RPC request failed", err = exc.msg, id, remote = client.remote
      raise exc

  let req = client.request(requestData)
  client.complete(req, id)

proc call*(
    client: RpcClient, name: string, params: JsonNode
): Future[JsonString] {.async: (raises: [CancelledError, JsonRpcError], raw: true).} =
  client.call(name, params.paramsTx)

proc callBatch*(
    client: RpcClient, calls: seq[RequestTx]
): Future[seq[ResponseRx2]] {.
    async: (raises: [CancelledError, JsonRpcError], raw: true)
.} =
  if calls.len == 0:
    let res = Future[seq[ResponseRx2]].Raising([CancelledError, JsonRpcError]).init(
        "empty batch"
      )
    res.complete(default(seq[ResponseRx2]))
    return res

  let requestData = JrpcSys.withWriter(writer):
    writer.writeArray:
      for call in calls:
        writer.writeValue(call)

  debug "Sending JSON-RPC batch", len = requestData.len, remote = client.remote

  proc complete(
      client: RpcClient, request: auto
  ): Future[seq[ResponseRx2]] {.async: (raises: [CancelledError, JsonRpcError]).} =
    try:
      let resData = await request
      debug "Processing JSON-RPC batch response",
        len = resData.len, remote = client.remote
      parseResponse(resData, seq[ResponseRx2])
    except JsonRpcError as exc:
      debug "JSON-RPC batch request failed", err = exc.msg, remote = client.remote
      raise exc

  let req = client.request(requestData)
  client.complete(req)

proc prepareBatch*(client: RpcClient): RpcBatchCallRef =
  RpcBatchCallRef(client: client)

proc send*(
    batch: RpcBatchCallRef
): Future[Result[seq[RpcBatchResponse], string]] {.
    async: (raises: [CancelledError], raw: true)
.} =
  if batch.batch.len == 0:
    let res = Future[Result[seq[RpcBatchResponse], string]]
      .Raising([CancelledError])
      .init("empty batch")
    res.complete(
      Result[seq[RpcBatchResponse], string].ok(default(seq[RpcBatchResponse]))
    )
    return res

  var lastId: int
  var map = initTable[int, int]()

  let requestData = JrpcSys.withWriter(writer):
    writer.writeArray:
      for i, item in batch.batch:
        lastId = batch.client.getNextId()
        map[lastId] = i
        writer.writeValue(requestTx(item.meth, item.params, lastId))

  debug "Sending JSON-RPC batch",
    len = requestData.len, lastId, remote = batch.client.remote

  proc complete(
      client: RpcClient, request: auto, map: sink Table[int, int], lastId: int
  ): Future[Result[seq[RpcBatchResponse], string]] {.async: (raises: [CancelledError]).} =
    var
      map = move(map) # 2.0 compat
      res =
        try:
          let resData = await request
          debug "Processing JSON-RPC batch response",
            len = resData.len, lastId, remote = client.remote

          parseResponse(resData, seq[ResponseRx2])
        except JsonRpcError as exc:
          debug "JSON-RPC batch request failed", err = exc.msg, remote = client.remote

          return err(exc.msg)
      responses = newSeq[RpcBatchResponse](map.len)

    for i, response in res.mpairs():
      let id = response.id.num
      var index: int
      if not map.pop(id, index):
        return err("cannot find message id: " & $lastId & " in response " & $i)

      case response.kind
      of ResponseKind.rkError:
        responses[index] =
          RpcBatchResponse(error: Opt.some(JrpcSys.encode(response.error)))
      of ResponseKind.rkResult:
        responses[index] = RpcBatchResponse(result: move(response.result))

    # In case the response is incomplete, we should say something about the
    # missing requests
    for _, index in map:
      responses[index] = RpcBatchResponse(
        error: Opt.some(
          JrpcSys.encode(
            ResponseError(code: INTERNAL_ERROR, message: "Missing response from server")
          )
        )
      )

    ok(responses)
  let req = batch.client.request(requestData)
  batch.client.complete(req, map, lastId)

# ------------------------------------------------------------------------------
# Signature processing
# ------------------------------------------------------------------------------

macro createRpcSigs*(Format: type SerializationFormat, clientType: untyped, filePath: static[string]): untyped =
  ## Takes a file of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  cresteSignaturesFromString(clientType, staticRead($filePath.replace('\\', '/')), Format)

template createRpcSigs*(clientType: untyped, filePath: string): untyped =
  createRpcSigs(JrpcConv, clientType, filePath)

macro createRpcSigsFromString*(Format: type SerializationFormat, clientType: untyped, sigString: static[string]): untyped =
  ## Takes a string of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  cresteSignaturesFromString(clientType, sigString, Format)

template createRpcSigsFromString*(clientType: untyped, sigString: string): untyped =
  createRpcSigsFromString(JrpcConv, clientType, sigString)

macro createSingleRpcSig*(clientType: untyped, alias: static[string], procDecl: untyped): untyped =
  ## Takes a single forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  doAssert procDecl.len == 1, "Only accept single proc definition"
  let procDecl = procDecl[0]
  procDecl.expectKind nnkProcDef
  result = createRpcFromSig(clientType, procDecl, ident(alias))

macro createRpcSigsFromNim*(Format: type SerializationFormat, clientType: untyped, procList: untyped): untyped =
  ## Takes a list of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  processRpcSigs(clientType, procList, Format)

template createRpcSigsFromNim*(clientType: untyped, procList: untyped): untyped =
  createRpcSigsFromNim(JrpcConv, clientType, procList)

{.pop.}
