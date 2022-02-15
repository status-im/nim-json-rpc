import
  std/[tables],
  pkg/[chronos, chronicles],
  ../client, ./config

export client

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

else:
  import std/[uri, strutils]
  import stew/byteutils
  import pkg/websock/[websock, extensions/compression/deflate]

  type
    RpcWebSocketClient* = ref object of RpcClient
      transport*: WSSession
      uri*: Uri
      loop*: Future[void]

proc new*(T: type RpcWebSocketClient): T =
  T()

proc newRpcWebSocketClient*: RpcWebSocketClient =
  ## Creates a new client instance.
  RpcWebSocketClient.new()

method call*(self: RpcWebSocketClient, name: string,
             params: JsonNode): Future[Response] {.
    async, gcsafe, raises: [Defect, CatchableError].} =
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
      while ws.readystate != ReadyState.Closed:
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

when useNews:
  proc connect*(
      client: RpcWebSocketClient,
      uri: string,
      headers: StringTableRef = nil,
      compression = false) {.async.} =
    if compression:
      warn "compression is not supported with the news back-end"
    var headers = headers
    if headers.isNil:
      headers = newStringTable({"Origin": "http://localhost"})
    elif "Origin" notin headers:
      # TODO: This is a hack, because the table might be case sensitive. Ideally strtabs module has
      # to be extended with case insensitive accessors.
      headers["Origin"] = "http://localhost"
    client.transport = await newWebSocket(uri, headers)
    client.uri = uri
    client.loop = processData(client)
else:
  proc connect*(
      client: RpcWebSocketClient, uri: string,
      compression = false,
      flags: set[TLSFlags] = {NoVerifyHost, NoVerifyServerName}) {.async.} =
    var ext: seq[ExtFactory] = if compression: @[deflateFactory()]
                               else: @[]
    let uri = parseUri(uri)
    let ws = await WebSocket.connect(
      uri=uri,
      factories=ext,
      flags=flags
    )
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
