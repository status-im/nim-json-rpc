# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[uri, strutils],
  pkg/websock/[websock, extensions/compression/deflate],
  pkg/[chronos, chronos/apps/http/httptable, chronicles],
  stew/byteutils,
  ../errors

# avoid clash between Json.encode and Base64Pad.encode
import ../client except encode

logScope:
  topics = "JSONRPC-WS-CLIENT"

type
  RpcWebSocketClient* = ref object of RpcClient
    transport*: WSSession
    uri*: Uri
    loop*: Future[void]
    getHeaders*: GetJsonRpcRequestHeaders

{.push gcsafe, raises: [].}

proc new*(
    T: type RpcWebSocketClient, getHeaders: GetJsonRpcRequestHeaders = nil): T =
  T(getHeaders: getHeaders)

proc newRpcWebSocketClient*(
    getHeaders: GetJsonRpcRequestHeaders = nil): RpcWebSocketClient =
  ## Creates a new client instance.
  RpcWebSocketClient.new(getHeaders)

method call*(client: RpcWebSocketClient, name: string,
             params: RequestParamsTx): Future[JsonString] {.async, gcsafe.} =
  ## Remotely calls the specified RPC method.
  if client.transport.isNil:
    raise newException(JsonRpcError,
      "Transport is not initialised (missing a call to connect?)")

  let id = client.getNextId()
  var value = requestTxEncode(name, params, id) & "\r\n"

  # completed by processMessage.
  var newFut = newFuture[JsonString]()
  # add to awaiting responses
  client.awaiting[id] = newFut

  await client.transport.send(value)
  return await newFut

method callBatch*(client: RpcWebSocketClient,
                  calls: RequestBatchTx): Future[ResponseBatchRx]
                    {.gcsafe, async.} =
  if client.transport.isNil:
    raise newException(JsonRpcError,
      "Transport is not initialised (missing a call to connect?)")

  if client.batchFut.isNil or client.batchFut.finished():
    client.batchFut = newFuture[ResponseBatchRx]()

  let jsonBytes = requestBatchEncode(calls) & "\r\n"
  await client.transport.send(jsonBytes)

  return await client.batchFut

proc processData(client: RpcWebSocketClient) {.async.} =
  var error: ref CatchableError

  template processError() =
    for k, v in client.awaiting:
      v.fail(error)
    if client.batchFut.isNil.not and not client.batchFut.completed():
      client.batchFut.fail(error)
    client.awaiting.clear()

  let ws = client.transport
  try:
    while ws.readyState != ReadyState.Closed:
      var value = await ws.recvMsg(MaxMessageBodyBytes)

      if value.len == 0:
        # transmission ends
        break

      let res = client.processMessage(string.fromBytes(value))
      if res.isErr:
        error "Error when processing RPC message", msg=res.error
        error = newException(JsonRpcError, res.error)
        processError()

  except CatchableError as e:
    error = e

  await client.transport.close()

  client.transport = nil

  if client.awaiting.len != 0:
    if error.isNil:
      error = newException(IOError, "Transport was closed while waiting for response")
    processError()
  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc addExtraHeaders(
    headers: var HttpTable,
    client: RpcWebSocketClient,
    extraHeaders: HttpTable) =
  # Apply client instance overrides
  if client.getHeaders != nil:
    for header in client.getHeaders():
      headers.add(header[0], header[1])

  # Apply call specific overrides
  for header in extraHeaders.stringItems:
    headers.add(header.key, header.value)

  # Apply default origin
  discard headers.hasKeyOrPut("Origin", "http://localhost")

proc connect*(
    client: RpcWebSocketClient,
    uri: string,
    extraHeaders: HttpTable = default(HttpTable),
    compression = false,
    hooks: seq[Hook] = @[],
    flags: set[TLSFlags] = {}) {.async.} =
  proc headersHook(ctx: Hook, headers: var HttpTable): Result[void, string] =
    headers.addExtraHeaders(client, extraHeaders)
    ok()
  var ext: seq[ExtFactory] = if compression: @[deflateFactory()]
                              else: @[]
  let uri = parseUri(uri)
  let ws = await WebSocket.connect(
    uri=uri,
    factories=ext,
    hooks=hooks & Hook(append: headersHook),
    flags=flags)
  client.transport = ws
  client.uri = uri
  client.loop = processData(client)

method isConnected*(client: RpcWebSocketClient): bool =
  not client.transport.isNil()

method close*(client: RpcWebSocketClient) {.async.} =
  await client.loop.cancelAndWait()
  if not client.transport.isNil:
    await client.transport.close()
    client.transport = nil
