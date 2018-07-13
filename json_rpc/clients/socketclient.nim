import ../client, asyncdispatch2, tables, json

type
  RpcSocketClient* = ref object of RpcClient
    transport*: StreamTransport
    address*: TransportAddress

const defaultMaxRequestLength* = 1024 * 128

proc newRpcSocketClient*: RpcSocketClient =
  ## Creates a new client instance.
  new result
  result.initRpcClient()

proc call*(self: RpcSocketClient, name: string,
          params: JsonNode): Future[Response] {.async.} =
  ## Remotely calls the specified RPC method.
  let id = self.getNextId()
  var value = $rpcCallNode(name, params, id) & "\c\l"

  if self.transport.isNil:
    var connectStr = ""
    raise newException(ValueError, "Transport is not initialised (missing a call to connect?)")
  let res = await self.transport.write(value)
  # TODO: Add actions when not full packet was send, e.g. disconnect peer.
  assert(res == len(value))

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut
  result = await newFut

proc processData(client: RpcSocketClient) {.async.} =
  while true:
    var value = await client.transport.readLine(defaultMaxRequestLength)
    if value == "":
      # transmission ends
      client.transport.close
      break

    client.processMessage(value)
  # async loop reconnection and waiting
  client.transport = await connect(client.address)

proc connect*(client: RpcSocketClient, address: string, port: Port) {.async.} =
  let addresses = resolveTAddress(address, port)
  client.transport = await connect(addresses[0])
  client.address = addresses[0]
  asyncCheck processData(client)