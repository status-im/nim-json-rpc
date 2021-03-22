import
  std/[json, tables],
  ../client, chronos

type
  RpcSocketClient* = ref object of RpcClient
    transport*: StreamTransport
    address*: TransportAddress
    loop*: Future[void]

const defaultMaxRequestLength* = 1024 * 128

proc new*(T: type RpcSocketClient): T =
  T()

proc newRpcSocketClient*: RpcSocketClient =
  ## Creates a new client instance.
  RpcSocketClient.new()

method call*(self: RpcSocketClient, name: string,
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

  let res = await self.transport.write(value)
  # TODO: Add actions when not full packet was send, e.g. disconnect peer.
  doAssert(res == len(value))

  return await newFut

proc processData(client: RpcSocketClient) {.async.} =
  while true:
    while true:
      var value = await client.transport.readLine(defaultMaxRequestLength)
      if value == "":
        # transmission ends
        await client.transport.closeWait()
        break

      # TODO handle exceptions
      client.processMessage(value)

    # async loop reconnection and waiting
    client.transport = await connect(client.address)

proc connect*(client: RpcSocketClient, address: string, port: Port) {.async.} =
  let addresses = resolveTAddress(address, port)
  client.transport = await connect(addresses[0])
  client.address = addresses[0]
  client.loop = processData(client)

method close*(client: RpcSocketClient) {.async.} =
  # TODO: Stop the processData loop
  await client.transport.closeWait()
