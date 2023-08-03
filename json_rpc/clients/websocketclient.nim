import
  pkg/[chronos, chronos/apps/http/httptable, chronicles],
  stew/byteutils,
  ../client

export client

{.push raises: [Defect].}

logScope:
  topics = "JSONRPC-WS-CLIENT"

import std/[uri, strutils]
import pkg/websock/[websock, extensions/compression/deflate]

type
  RpcWebSocketClient* = ref object of RpcClient
    transport*: WSSession
    uri*: Uri
    loop*: Future[void]
    getHeaders*: GetJsonRpcRequestHeaders

proc new*(
    T: type RpcWebSocketClient, getHeaders: GetJsonRpcRequestHeaders = nil): T =
  T(getHeaders: getHeaders)

proc newRpcWebSocketClient*(
    getHeaders: GetJsonRpcRequestHeaders = nil): RpcWebSocketClient =
  ## Creates a new client instance.
  RpcWebSocketClient.new(getHeaders)

method call*(self: RpcWebSocketClient, name: string,
             params: JsonNode): Future[Response] {.async, gcsafe.} =
  ## Remotely calls the specified RPC method.
  if self.transport.isNil:
    raise newException(ValueError,
                    "Transport is not initialised (missing a call to connect?)")

  # completed by processMessage.
  let
    newFut = newFuture[Response]()
    id = self.getNextId()
    message = $rpcCallNode(name, params, id) & "\r\n"

  # add to awaiting responses
  self.awaiting[id] = newFut

  await self.transport.send(message)

  debug "Message sent to RPC server", name, msg_len = len(message)
  trace "Message", msg = message

  return await newFut

proc processData(client: RpcWebSocketClient) {.async.} =
  var error: ref CatchableError

  let ws = client.transport
  try:
    while ws.readyState != ReadyState.Closed:
      var value = await ws.recvMsg()

      if value.len == 0:
        # transmission ends
        break

      client.processMessage(string.fromBytes(value))
  except CatchableError as e:
    error = e

  await client.transport.close()

  client.transport = nil

  if client.awaiting.len != 0:
    if error.isNil:
      error = newException(IOError, "Transport was closed while waiting for response")
    for k, v in client.awaiting:
      v.fail(error)
    client.awaiting.clear()
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

method close*(client: RpcWebSocketClient) {.async.} =
  await client.loop.cancelAndWait()
  if not client.transport.isNil:
    await client.transport.close()
    client.transport = nil
