import asyncnet, asyncdispatch, tables, json, oids, ethcalls, macros

type
  RpcClient* = ref object
    socket: AsyncSocket
    awaiting: Table[string, Future[Response]]
    address: string
    port: Port
  Response* = tuple[error: bool, result: JsonNode]

proc newRpcClient*(): RpcClient =
  ## Creates a new ``RpcClient`` instance. 
  RpcClient(
    socket: newAsyncSocket(),
    awaiting: initTable[string, Future[Response]]()
  )

proc call*(self: RpcClient, name: string, params: JsonNode): Future[Response] {.async.} =
  ## Remotely calls the specified RPC method.
  let id = $genOid()
  let msg = %{"jsonrpc": %"2.0", "method": %name, "params": params, "id": %id}
  await self.socket.send($msg & "\c\l")

  # Completed by processMessage.
  var newFut = newFuture[Response]()
  self.awaiting[id] = newFut  # add to awaiting responses
  result = await newFut

proc isNull(node: JsonNode): bool = node.kind == JNull

proc processMessage(self: RpcClient, line: string) =
  let node = parseJson(line)
  
  assert node.hasKey("jsonrpc")
  assert node["jsonrpc"].str == "2.0"
  assert node.hasKey("id")
  assert self.awaiting.hasKey(node["id"].str)

  if node["error"].kind == JNull:
    self.awaiting[node["id"].str].complete((false, node["result"]))
    self.awaiting.del(node["id"].str)
  else:
    # If the node id is null, we cannot complete the future.
    if not node["id"].isNull: 
      self.awaiting[node["id"].str].complete((true, node["error"]))
      # TODO: Safe to delete here?
      self.awaiting.del(node["id"].str)

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

proc makeTemplate(name: string, params: NimNode, body: NimNode, starred: bool): NimNode =
  # set up template AST
  result = newNimNode(nnkTemplateDef)
  if starred: result.add postFix(ident(name), "*")
  else: result.add ident(name)
  result.add newEmptyNode(), newEmptyNode(), params, newEmptyNode(), newEmptyNode(), body

proc appendFormalParam(formalParams: NimNode, identName, typeName: string) =
  # set up formal params AST
  formalParams.expectKind(nnkFormalParams)
  if formalParams.len == 0: formalParams.add newEmptyNode()
  var identDef = newIdentDefs(ident(identName), ident(typeName))
  formalParams.add identDef

macro generateCalls: untyped =
  ## Generate templates for client calls so that:
  ##   client.call("web3_clientVersion", params)
  ## can be written as:
  ##   client.web3_clientVersion(params)
  result = newStmtList()
  for callName in ETHEREUM_RPC_CALLS:
    var
      params = newNimNode(nnkFormalParams)
      call = newCall(newDotExpr(ident("client"), ident("call")), newStrLitNode(callName), ident("params"))
      body = newStmtList().add call
      templ = makeTemplate(callName, params, body, true)
    params.add newNimNode(nnkBracketExpr).add(ident("Future"), ident("Response"))
    params.appendFormalParam("client", "RpcClient")
    params.appendFormalParam("params", "JsonNode")
    result.add templ

# generate all client ethereum rpc calls
generateCalls()
