import tables, json, macros
import asyncdispatch2
from strutils import toLowerAscii
import jsonmarshal
export asyncdispatch2

type
  RpcClient*[T, A] = ref object
    transp*: T
    awaiting: Table[string, Future[Response]]
    address: A
    nextId: int64

  Response* = tuple[error: bool, result: JsonNode]

const defaultMaxRequestLength* = 1024 * 128

proc newRpcClient*[T, A](): RpcClient[T, A] =
  ## Creates a new ``RpcClient`` instance.
  result = RpcClient[T, A](awaiting: initTable[string, Future[Response]](), nextId: 1)

proc genCall(rpcType, callName, writeCode: NimNode): NimNode =
  let res = newIdentNode("result")
  result = quote do:
    proc `callName`*(self: `rpcType`, name: string,
              params: JsonNode): Future[Response] {.async.} =
      ## Remotely calls the specified RPC method.
      let id = $self.nextId
      self.nextId.inc
      var
        value {.inject.} =
          $ %{"jsonrpc": %"2.0",
            "method": %name,
            "params": params,
            "id": %id} & "\c\l"
      template client: untyped = self
      let res = await `writeCode`
      # TODO: Add actions when not full packet was send, e.g. disconnect peer.
      assert(res == len(value))

      # completed by processMessage.
      var newFut = newFuture[Response]()
      # add to awaiting responses
      self.awaiting[id] = newFut
      `res` = await newFut

template asyncRaise[T](fut: Future[T], errType: typedesc, msg: string) =
  fut.fail(newException(errType, msg))

macro checkGet(node: JsonNode, fieldName: string,
               jKind: static[JsonNodeKind]): untyped =
  let n = genSym(ident = "n") #`node`{`fieldName`}
  result = quote:
    let `n` = `node`{`fieldname`}
    if `n`.isNil or `n`.kind == JNull:
      raise newException(ValueError,
        "Message is missing required field \"" & `fieldName` & "\"")
    if `n`.kind != `jKind`.JsonNodeKind:
      raise newException(ValueError,
        "Expected " & $(`jKind`.JsonNodeKind) & ", got " & $`n`.kind)
  case jKind
  of JBool: result.add(quote do: `n`.getBool)
  of JInt: result.add(quote do: `n`.getInt)
  of JString: result.add(quote do: `n`.getStr)
  of JFloat: result.add(quote do: `n`.getFloat)
  of JObject: result.add(quote do: `n`.getObject)
  else: discard

proc processMessage[T, A](self: RpcClient[T, A], line: string) =
  # Note: this doesn't use any transport code so doesn't need to be differentiated.
  let node = parseJson(line)  # TODO: Check errors

  # TODO: Use more appropriate exception objects
  let id = checkGet(node, "id", JString)
  if not self.awaiting.hasKey(id):
    raise newException(ValueError,
      "Cannot find message id \"" & node["id"].str & "\"")
  
  let version = checkGet(node, "jsonrpc", JString)
  if version != "2.0":
    self.awaiting[id].asyncRaise(ValueError,
      "Unsupported version of JSON, expected 2.0, received \"" & version & "\"")

  let errorNode = node{"error"}
  if errorNode.isNil or errorNode.kind == JNull:
    var res = node{"result"}
    if not res.isNil:
      self.awaiting[id].complete((false, res))
    self.awaiting.del(id)
    # TODO: actions on unable find result node
  else:
    self.awaiting[id].fail(newException(ValueError, $errorNode))
    self.awaiting.del(id)

proc genProcessData(rpcType, processDataName, readCode, afterReadCode, closeCode: NimNode): NimNode =
  result = quote do:
    proc `processDataName`(clientTransport: `rpcType`) {.async.} =
      while true:
        var maxRequestLength {.inject.} = defaultMaxRequestLength
        template client: untyped = clientTransport
        var value {.inject.} = await `readCode`
        `afterReadCode`
        if value == "":
          # transmission ends
          `closeCode`
          break

        processMessage(clientTransport, value)
      # async loop reconnection and waiting
      clientTransport.transp = await connect(clientTransport.address)

proc genConnect(rpcType, connectName, processDataName, connectCode: NimNode): NimNode =
  result = quote do:
    proc `connectName`*(clientTransport: `rpcType`, address: string, port: Port) {.async.} =
      var
        address {.inject.} = address
        port {.inject.} = port
      template client: untyped = clientTransport
      `connectCode`
      asyncCheck `processDataName`(clientTransport)

macro defineRpcClientTransport*(transType, addrType: untyped, prefix: string = "", body: untyped = nil): untyped =
  var
    writeCode = quote do:
      client.transp.write(value)
    readCode = quote do:
      client.transp.readLine(defaultMaxRequestLength)
    closeCode = quote do:
      client.transp.close
    connectCode = quote do:
      # TODO: `address` hostname can be resolved to many IP addresses, we are using
      # first one, but maybe it would be better to iterate over all IP addresses
      # and try to establish connection until it will not be established.
      let addresses = resolveTAddress(address, port)
      client.transp = await connect(addresses[0])
      client.address = addresses[0]
    afterReadCode = newStmtList()

  if body != nil:
    body.expectKind nnkStmtList
    for item in body:
      item.expectKind nnkCall
      item[0].expectKind nnkIdent
      item[1].expectKind nnkStmtList
      let
        verb = $item[0]
        code = item[1]

      case verb.toLowerAscii
      of "write":
        # `client`, the RpcClient
        # `value`, the data to be sent to the server
        writeCode = code
      of "read":
        # `client`, the RpcClient
        # `maxRequestLength`, initially set to defaultMaxRequestLength
        readCode = code
      of "close":
        # `client`, the RpcClient
        # `value`, the data returned from the server
        # `maxRequestLength`, initially set to defaultMaxRequestLength
        closeCode = code
      of "connect":
        # `client`, the RpcClient
        # `address`, server destination address string
        # `port`, server destination port
        connectCode = code
      of "afterread":
        # `client`, the RpcClient
        # `value`, the data returned from the server           
        # `maxRequestLength`, initially set to defaultMaxRequestLength
        afterReadCode = code
      else: error("Unknown RPC verb \"" & verb & "\"")
      
  result = newStmtList()
  let
    rpcType = quote: RpcClient[`transType`, `addrType`]
    processDataName = newIdentNode(prefix.strVal & "processData")
    connectName = newIdentNode(prefix.strVal & "connect")
    callName = newIdentNode(prefix.strVal & "call")

  result.add(genProcessData(rpcType, processDataName, readCode, afterReadCode, closeCode))
  result.add(genConnect(rpcType, connectName, processDataName, connectCode))
  result.add(genCall(rpcType, callName, writeCode))
  
  when defined(nimDumpRpcs):
    echo "defineClient:\n", result.repr

# Define default stream server
# TODO: Move this into a separate unit so users can define 'connect', 'call' etc without requiring a prefix?

defineRpcClientTransport(StreamTransport, TransportAddress)

type RpcStreamClient* = RpcClient[StreamTransport, TransportAddress]

proc newRpcStreamClient*(): RpcStreamClient = 
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcClient[StreamTransport, TransportAddress]()

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
  result[0] = nnkPostFix.newTree(ident"*", newIdentNode($procName))

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
  parameters.insert(1, nnkIdentDefs.newTree(ident"client", ident"RpcClient",
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
    # actual return value, `rpcResult`.result
    jsonRpcResult = nnkDotExpr.newTree(rpcResult, newIdentNode("result"))

  # perform rpc call
  callBody.add(quote do:
    # `rpcResult` is of type `Response`
    let `rpcResult` = await `clientIdent`.call(`pathStr`, `jsonParamIdent`)
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
