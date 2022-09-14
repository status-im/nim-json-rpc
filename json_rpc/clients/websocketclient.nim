import
  pkg/[chronos, chronos/apps/http/httptable, chronicles],
  stew/byteutils,
  ../client, ./config

export client

# TODO needs fixes in news
# {.push raises: [Defect].}

logScope:
  topics = "JSONRPC-WS-CLIENT"

when useNews:
  const newsUseChronos = true
  include pkg/news

  type
    RpcWebSocketClient* = ref object of RpcClient
      transport*: WebSocket
      uri*: string
      loop*: Future[void]
      getHeaders*: GetJsonRpcRequestHeaders

else:
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
  let id = self.getNextId()
  var value = $rpcCallNode(name, params, id) & "\r\n"
  if self.transport.isNil:
    raise newException(ValueError,
                    "Transport is not initialised (missing a call to connect?)")

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut

  await self.transport.send(value)
  return await newFut

proc processData(client: RpcWebSocketClient) {.async.} =
  var error: ref CatchableError

  when useNews:
    try:
      while true:
        var value = await client.transport.receiveString()
        if value == "":
          # transmission ends
          break

        client.processMessage(value)
    except CatchableError as e:
      error = e

    client.transport.close()
  else:
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

when useNews:
  func toStringTable(headersTable: HttpTable): StringTableRef =
    let res = newStringTable(modeCaseInsensitive)
    for header in headersTable:
      res[header.key] = header.value.join(",")
    res

  proc connect*(
      client: RpcWebSocketClient,
      uri: string,
      extraHeaders: HttpTable = default(HttpTable),
      compression = false) {.async.} =
    if compression:
      warn "compression is not supported with the news back-end"
    var headers = HttpTable.init()
    headers.addExtraHeaders(client, extraHeaders)
    client.transport = await newWebSocket(uri, headers.toStringTable())
    client.uri = uri
    client.loop = processData(client)
else:
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
    when useNews:
      client.transport.close()
    else:
      await client.transport.close()
    client.transport = nil
