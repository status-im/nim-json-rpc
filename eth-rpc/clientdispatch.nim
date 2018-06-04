import tables, json, macros
import asyncdispatch2
import jsonmarshal

type
  RpcClient* = ref object
    transp: StreamTransport
    awaiting: Table[string, Future[Response]]
    address: TransportAddress
    nextId: int64
  Response* = tuple[error: bool, result: JsonNode]

proc newRpcClient*(): RpcClient =
  ## Creates a new ``RpcClient`` instance.
  RpcClient(awaiting: initTable[string, Future[Response]](), nextId: 1)

proc close*(self: RpcClient) =
  ## Closes ``RpcClient`` instance.
  self.transp.close()

proc call*(self: RpcClient, name: string,
           params: JsonNode): Future[Response] {.async.} =
  ## Remotely calls the specified RPC method.
  let id = $self.nextId
  self.nextId.inc
  var msg = $ %{"jsonrpc": %"2.0", "method": %name,
                "params": params, "id": %id} & "\c\l"
  discard await self.transp.write(cast[pointer](addr msg[0]), len(msg))

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut
  result = await newFut

macro checkGet(node: JsonNode, fieldName: string,
               jKind: static[JsonNodeKind]): untyped =
  let n = genSym(ident = "n") #`node`{`fieldName`}
  result = quote:
    let `n` = `node`{`fieldname`}
    if `n`.isNil:
      raise newException(ValueError,
                    "Message is missing required field \"" & `fieldName` & "\"")
    if `n`.kind != `jKind`.JsonNodeKind:
      raise newException(ValueError,
   "Expected " & $(`jKind`.JsonNodeKind) & ", got " & $`node`[`fieldName`].kind)

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
  if version != "2.0":
    raise newException(ValueError,
      "Unsupported version of JSON, expected 2.0, received \"" & version & "\"")

  let id = checkGet(node, "id", JString)
  if not self.awaiting.hasKey(id):
    raise newException(ValueError,
                       "Cannot find message id \"" & node["id"].str & "\"")

  let errorNode = node{"error"}
  if errorNode.isNil or errorNode.kind == JNull:
    var res = node{"result"}
    if not res.isNil:
      self.awaiting[id].complete((false, res))
    self.awaiting.del(id)
    # TODO: actions on unable find result node
  else:
    self.awaiting[id].complete((true, errorNode))
    self.awaiting.del(id)

proc connect*(self: RpcClient, address: TransportAddress): Future[void]

proc processData(self: RpcClient) {.async.} =
  while true:
    # read until no data
    let line = await self.transp.readLine()

    if line == "":
      # transmission ends
      self.transp.close()  # TODO: Do we need to drop/reacquire sockets?
      break

    processMessage(self, line)
  # async loop reconnection and waiting
  await connect(self, self.address)

proc connect*(self: RpcClient, address: TransportAddress) {.async.} =
  self.transp = await connect(address)
  self.address = address
  asyncCheck processData(self)

proc createRpcProc(procName, parameters, callBody: NimNode): NimNode =
  # parameters come as a tree
  var paramList = newSeq[NimNode]()
  for p in parameters: paramList.add(p)

  result = newProc(procName, paramList, callBody)           # build proc
  result.addPragma ident"async"                             # make proc async
  result[0] = nnkPostFix.newTree(ident"*",
                                 newIdentNode($procName))  # export this proc

proc toJsonArray(parameters: NimNode): NimNode =
  # outputs an array of jsonified parameters
  # ie; %[%a, %b, %c]
  parameters.expectKind nnkFormalParams
  var items = newNimNode(nnkBracket)
  for i in 2 ..< parameters.len:
    let curParam = parameters[i][0]
    if curParam.kind != nnkEmpty:
      items.add(nnkPrefix.newTree(ident"%", curParam))
  result = nnkPrefix.newTree(bindSym("%", brForceOpen), items)

proc createRpcFromSig*(rpcDecl: NimNode): NimNode =
  # Each input parameter in the rpc signature is converted
  # to json with `%`.
  # Return types are then converted back to native Nim types.
  let iJsonNode = newIdentNode("JsonNode")

  var parameters = rpcDecl.findChild(it.kind == nnkFormalParams).copy
  # ensure we have at least space for a return parameter
  if parameters.isNil or parameters.kind == nnkEmpty or parameters.len == 0:
    parameters = nnkFormalParams.newTree(iJsonNode)

  let
    procName = rpcDecl.name
    pathStr = $procName
    returnType =
      # if no return type specified, defaults to JsonNode
      if parameters[0].kind == nnkEmpty: iJsonNode
      else: parameters[0]
    customReturnType = returnType != iJsonNode

  # insert rpc client as first parameter
  parameters.insert(1, nnkIdentDefs.newTree(ident"client",
                                            ident"RpcClient", newEmptyNode()))

  let
    # variable used to send json to the server
    jsonParamIdent = genSym(nskVar, "jsonParam")
    # json array of marshalled parameters
    jsonParamArray = parameters.toJsonArray()
  var
    # populate json params - even rpcs with no parameters have an empty json
    # array node sent
    callBody = newStmtList().add(quote do:
      var `jsonParamIdent` = `jsonParamArray`
    )

  # convert return type to Future
  parameters[0] = nnkBracketExpr.newTree(ident"Future", returnType)
  # create rpc proc
  result = createRpcProc(procName, parameters, callBody)

  let
    rpcResult = genSym(nskLet, "res") # temporary variable to hold `Response`
                                      # from rpc call
    procRes = ident"result"           # proc return variable
    jsonRpcResult =                   # actual return value, `rpcResult`.result
      nnkDotExpr.newTree(rpcResult, newIdentNode("result"))

  # perform rpc call
  callBody.add(quote do:
    # `rpcResult` is of type `Response`
    let `rpcResult` = await client.call(`pathStr`, `jsonParamIdent`)
    # TODO: is raise suitable here?
    if `rpcResult`.error: raise newException(ValueError, $`rpcResult`.result)
  )

  if customReturnType:
    # marshal json to native Nim type
    callBody.add(jsonToNim(procRes, returnType, jsonRpcResult, "result"))
  else:
    # native json expected so no work
    callBody.add(quote do:
      `procRes` = `rpcResult`.result
      )
  when defined(nimDumpRpcs):
    echo pathStr, ":\n", result.repr

proc processRpcSigs(parsedCode: NimNode): NimNode =
  result = newStmtList()

  for line in parsedCode:
    if line.kind == nnkProcDef:
      var procDef = createRpcFromSig(line)
      result.add(procDef)

macro createRpcSigs*(filePath: static[string]): untyped =
  ## Takes a file of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  result = processRpcSigs(staticRead($filePath).parseStmt())
