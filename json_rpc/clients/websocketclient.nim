import ../client, chronos, tables, json

const newsUseChronos = true
include news

type
  RpcWebSocketClient* = ref object of RpcClient
    transport*: WebSocket
    uri*: string
    loop*: Future[void]

proc newRpcWebSocketClient*: RpcWebSocketClient =
  ## Creates a new client instance.
  new result
  result.initRpcClient()

method call*(self: RpcWebSocketClient, name: string,
          params: JsonNode): Future[Response] {.async.} =
  ## Remotely calls the specified RPC method.
  let id = self.getNextId()
  var value = $rpcCallNode(name, params, id) & "\c\l"
  if self.transport.isNil:
    raise newException(ValueError,
                    "Transport is not initialised (missing a call to connect?)")
  # echo "Sent msg: ", value

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut

  await self.transport.send(value)
  result = await newFut

proc processData(client: RpcWebSocketClient) {.async.} =
  while true:
    while true:
      var value = await client.transport.receivePacket()
      if value == "":
        # transmission ends
        client.transport.close()
        break

      client.processMessage(value)
    # async loop reconnection and waiting
    client.transport = await newWebSocket(client.uri)

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
  # TODO: Stop the processData loop
  client.transport.close()
