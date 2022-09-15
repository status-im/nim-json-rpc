import
  std/[tables, macros],
  chronos,
  ./jsonmarshal

from strutils import toLowerAscii, replace

export
  chronos, jsonmarshal, tables

type
  ClientId* = int64
  MethodHandler* = proc (j: JsonNode) {.gcsafe, raises: [Defect, CatchableError].}
  RpcClient* = ref object of RootRef
    awaiting*: Table[ClientId, Future[Response]]
    lastId: ClientId
    methodHandlers: Table[string, MethodHandler]
    onDisconnect*: proc() {.gcsafe, raises: [Defect].}

  Response* = JsonNode

  GetJsonRpcRequestHeaders* = proc(): seq[(string, string)] {.gcsafe, raises: [Defect].}

proc getNextId*(client: RpcClient): ClientId =
  client.lastId += 1
  client.lastId

proc rpcCallNode*(path: string, params: JsonNode, id: ClientId): JsonNode =
  %{"jsonrpc": %"2.0", "method": %path, "params": params, "id": %id}

method call*(client: RpcClient, name: string,
             params: JsonNode): Future[Response] {.
    base, async, gcsafe, raises: [Defect].} =
  discard

method close*(client: RpcClient): Future[void] {.
    base, async, gcsafe, raises: [Defect].} =
  discard

template `or`(a: JsonNode, b: typed): JsonNode =
  if a == nil: b else: a

proc processMessage*(self: RpcClient, line: string) =
  # Note: this doesn't use any transport code so doesn't need to be
  # differentiated.
  let node = try: parseJson(line)
  except CatchableError as exc: raise exc
  # TODO https://github.com/status-im/nimbus-eth2/issues/2430
  except Exception as exc: raise (ref ValueError)(msg: exc.msg, parent: exc)

  if "id" in node:
    let id = node{"id"} or newJNull()

    var requestFut: Future[Response]
    if not self.awaiting.pop(id.getInt(-1), requestFut):
      raise newException(ValueError, "Cannot find message id \"" & $id & "\"")

    let version = node{"jsonrpc"}.getStr()
    if version != "2.0":
      requestFut.fail(newException(ValueError,
        "Unsupported version of JSON, expected 2.0, received \"" & version & "\""))
    else:
      let result = node{"result"}
      if result.isNil:
        let error = node{"error"} or newJNull()
        requestFut.fail(newException(ValueError, $error))
      else:
        requestFut.complete(result)
  elif "method" in node:
    # This could be subscription notification
    let name = node["method"].getStr()
    let handler = self.methodHandlers.getOrDefault(name)
    if not handler.isNil:
      handler(node{"params"} or newJArray())
  else:
    raise newException(ValueError, "Invalid jsonrpc message: " & $node)

# Signature processing

proc createRpcProc(procName, parameters, callBody: NimNode): NimNode =
  # parameters come as a tree
  var paramList = newSeq[NimNode]()
  for p in parameters: paramList.add(p)

  # build proc
  result = newProc(procName, paramList, callBody)
  # make proc async
  result.addPragma ident"async"
  # export this proc
  result[0] = nnkPostfix.newTree(ident"*", newIdentNode($procName))

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

proc createRpcFromSig*(clientType, rpcDecl: NimNode): NimNode =
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
  parameters.insert(1, nnkIdentDefs.newTree(ident"client", ident($clientType),
                                            newEmptyNode()))

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
    # temporary variable to hold `Response` from rpc call
    rpcResult = genSym(nskLet, "res")
    clientIdent = newIdentNode("client")
    # proc return variable
    procRes = ident"result"

  # perform rpc call
  callBody.add(quote do:
    # `rpcResult` is of type `Response`
    let `rpcResult` = await `clientIdent`.call(`pathStr`, `jsonParamIdent`)
    if isNil(`rpcResult`):
      raise newException(InvalidResponse, "client.call returned nil")
  )

  if customReturnType:
    # marshal json to native Nim type
    callBody.add(jsonToNim(procRes, returnType, rpcResult, "result"))
  else:
    # native json expected so no work
    callBody.add quote do:
      `procRes` = `rpcResult`

  when defined(nimDumpRpcs):
    echo pathStr, ":\n", result.repr

proc processRpcSigs(clientType, parsedCode: NimNode): NimNode =
  result = newStmtList()

  for line in parsedCode:
    if line.kind == nnkProcDef:
      var procDef = createRpcFromSig(clientType, line)
      result.add(procDef)

proc setMethodHandler*(cl: RpcClient, name: string, callback: MethodHandler) =
  cl.methodHandlers[name] = callback

proc delMethodHandler*(cl: RpcClient, name: string) =
  cl.methodHandlers.del(name)

macro createRpcSigs*(clientType: untyped, filePath: static[string]): untyped =
  ## Takes a file of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  result = processRpcSigs(clientType, staticRead($filePath.replace('\\', '/')).parseStmt())
