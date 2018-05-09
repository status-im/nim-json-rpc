import asyncnet, asyncdispatch, tables, json, oids, ethcalls, macros

type
  RpcClient* = ref object
    socket: AsyncSocket
    awaiting: Table[string, Future[Response]]
    address: string
    port: Port
    nextId: int64
  Response* = tuple[error: bool, result: JsonNode]


proc newRpcClient*(): RpcClient =
  ## Creates a new ``RpcClient`` instance. 
  RpcClient(
    socket: newAsyncSocket(),
    awaiting: initTable[string, Future[Response]](),
    nextId: 1
  )

proc call*(self: RpcClient, name: string, params: JsonNode): Future[Response] {.async.} =
  ## Remotely calls the specified RPC method.
  let id = $self.nextId
  self.nextId.inc
  let msg = $ %{"jsonrpc": %"2.0", "method": %name, "params": params, "id": %id} & "\c\l"
  await self.socket.send(msg)

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut
  result = await newFut

macro checkGet(node: JsonNode, fieldName: string, jKind: static[JsonNodeKind]): untyped =
  result = quote do:
    if not node.hasKey(`fieldName`): raise newException(ValueError, "Message is missing required field \"" & `fieldName` & "\"")
    if `node`[`fieldName`].kind != `jKind`.JsonNodeKind: raise newException(ValueError, "Expected " & $(`jKind`.JsonNodeKind) & ", got " & $`node`[`fieldName`].kind)
  case jKind
  of JBool: result.add(quote do: `node`[`fieldName`].getBool)
  of JInt: result.add(quote do: `node`[`fieldName`].getInt)
  of JString: result.add(quote do: `node`[`fieldName`].getStr)
  of JFloat: result.add(quote do: `node`[`fieldName`].getFloat)
  of JObject: result.add(quote do: `node`[`fieldName`].getObject)
  else: discard

proc processMessage(self: RpcClient, line: string) =
  let node = parseJson(line)
  
  # TODO: Use more appropriate exception objects
  let version = checkGet(node, "jsonrpc", JString)
  if version != "2.0": raise newException(ValueError, "Unsupported version of JSON, expected 2.0, received \"" & version & "\"")
  let id = checkGet(node, "id", JString)
  if not self.awaiting.hasKey(id): raise newException(ValueError, "Cannot find message id \"" & node["id"].str & "\"")

  if node["error"].kind == JNull:
    self.awaiting[id].complete((false, node["result"]))
    self.awaiting.del(id)
  else:
    self.awaiting[id].complete((true, node["error"]))
    self.awaiting.del(id)

proc connect*(self: RpcClient, address: string, port: Port): Future[void]

proc processData(self: RpcClient) {.async.} =
  while true:
    # read until no data
    let line = await self.socket.recvLine()

    if line == "":
      # transmission ends
      self.socket.close()  # TODO: Do we need to drop/reacquire sockets?
      self.socket = newAsyncSocket()
      break
    
    processMessage(self, line)
  # async loop reconnection and waiting
  await connect(self, self.address, self.port)

proc connect*(self: RpcClient, address: string, port: Port) {.async.} =
  await self.socket.connect(address, port)
  self.address = address
  self.port = port
  asyncCheck processData(self)

macro generateCalls: untyped =
  ## Generate templates for client calls so that:
  ##   client.call("web3_clientVersion", params)
  ## can be written as:
  ##   client.web3_clientVersion(params)
  result = newStmtList()
  for callName in ETHEREUM_RPC_CALLS:
    let nameLit = ident(callName)
    result.add(quote do:
      template `nameLit`*(client: RpcClient, params: JsonNode): Future[Response] = client.call(`callName`, params)  # TODO: Back to template
    )

# generate all client ethereum rpc calls
generateCalls()
