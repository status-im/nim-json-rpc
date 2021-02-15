import
  std/[json, strtabs, tables],
  ../client, chronos

const newsUseChronos = true
include news

type
  RpcWebSocketClient* = ref object of RpcClient
    transport*: WebSocket
    uri*: string
    loop*: Future[void]

proc new*(T: type RpcWebSocketClient): T =
  T()

proc newRpcWebSocketClient*: RpcWebSocketClient =
  ## Creates a new client instance.
  RpcWebSocketClient.new()

method call*(self: RpcWebSocketClient, name: string,
             params: JsonNode): Future[Response] {.async.} =
  ## Remotely calls the specified RPC method.
  let id = self.getNextId()
  var value = $rpcCallNode(name, params, id) & "\r\n"
  if self.transport.isNil:
    raise newException(ValueError,
                    "Transport is not initialised (missing a call to connect?)")
  # echo "Sent msg: ", value

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut

  await self.transport.send(value)
  return await newFut

proc processData(client: RpcWebSocketClient) {.async.} =
  var error: ref CatchableError
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
  client.transport = nil

  if client.awaiting.len != 0:
    if error.isNil:
      error = newException(IOError, "Transport was closed while waiting for response")
    for k, v in client.awaiting:
      v.fail(error)
    client.awaiting.clear()
  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc connect*(client: RpcWebSocketClient, uri: string, headers: StringTableRef = nil) {.async.} =
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

method close*(client: RpcWebSocketClient) {.async.} =
  if not client.transport.isNil:
    client.loop.cancel()
