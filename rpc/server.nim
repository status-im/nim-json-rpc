import json, tables, strutils, options, macros, chronicles
import asyncdispatch2
import jsonmarshal

export asyncdispatch2, json, jsonmarshal, options

logScope:
  topics = "RpcServer"

type
  RpcJsonError* = enum rjeInvalidJson, rjeVersionError, rjeNoMethod, rjeNoId

  RpcJsonErrorContainer* = tuple[err: RpcJsonError, msg: string]

  # Procedure signature accepted as an RPC call by server
  RpcProc* = proc (params: JsonNode): Future[JsonNode]

  RpcClientTransport* = concept t
    t.write(var string) is Future[int]
    t.readLine(int) is Future[string]
    t.close
    t.remoteAddress() # Required for logging
    t.localAddress()

  RpcServerTransport* = concept t
    t.start
    t.stop
    t.close

  RpcProcessClient* = proc (server: RpcServerTransport, client: RpcClientTransport): Future[void] {.gcsafe.}

  RpcServer*[S: RpcServerTransport] = ref object
    servers*: seq[S]
    procs*: TableRef[string, RpcProc]

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

  RpcBindError* = object of Exception
  RpcAddressUnresolvableError* = object of Exception

const
  JSON_PARSE_ERROR* = -32700
  INVALID_REQUEST* = -32600
  METHOD_NOT_FOUND* = -32601
  INVALID_PARAMS* = -32602
  INTERNAL_ERROR* = -32603
  SERVER_ERROR* = -32000

  defaultMaxRequestLength = 1024 * 128

  jsonErrorMessages*: array[RpcJsonError, (int, string)] =
    [
      (JSON_PARSE_ERROR, "Invalid JSON"),
      (INVALID_REQUEST, "JSON 2.0 required"),
      (INVALID_REQUEST, "No method requested"),
      (INVALID_REQUEST, "No id specified")
    ]

proc newRpcServer*[S](): RpcServer[S] =
  new result
  result.procs = newTable[string, RpcProc]()
  result.servers = @[]

# Utility functions
# TODO: Move outside server
func `%`*(p: Port): JsonNode = %(p.int)

# Json state checking

template jsonValid*(jsonString: string, node: var JsonNode): (bool, string) =
  var
    valid = true
    msg = ""
  try: node = parseJson(line)
  except:
    valid = false
    msg = getCurrentExceptionMsg()
    debug "Cannot process json", json = jsonString, msg = msg
  (valid, msg)

proc checkJsonErrors*(line: string,
                      node: var JsonNode): Option[RpcJsonErrorContainer] =
  ## Tries parsing line into node, if successful checks required fields
  ## Returns: error state or none
  let res = jsonValid(line, node)
  if not res[0]:
    return some((rjeInvalidJson, res[1]))
  if not node.hasKey("id"):
    return some((rjeNoId, ""))
  if node{"jsonrpc"} != %"2.0":
    return some((rjeVersionError, ""))
  if not node.hasKey("method"):
    return some((rjeNoMethod, ""))
  return none(RpcJsonErrorContainer)

# Json reply wrappers

proc wrapReply*(id: JsonNode, value: JsonNode, error: JsonNode): string =
  let node = %{"jsonrpc": %"2.0", "result": value, "error": error, "id": id}
  return $node & "\c\l"

proc addErrorSending(name, writeCode: NimNode): NimNode =
  let
    res = newIdentNode("result")
    sendJsonErr = newIdentNode($name & "Json")
  result = quote do:
    proc `name`*[T: RpcClientTransport](clientTrans: T, code: int, msg: string, id: JsonNode,
                    data: JsonNode = newJNull()) {.async.} =
      ## Send error message to client
      let error = %{"code": %(code), "id": id, "message": %msg, "data": data}
      debug "Error generated", error = error, id = id
      var
        value {.inject.} = wrapReply(id, newJNull(), error)
        client {.inject.}: T
      shallowCopy(client, clientTrans)
      `res` = `writeCode`

    proc `sendJsonErr`*(state: RpcJsonError, clientTrans: RpcClientTransport, id: JsonNode,
                        data = newJNull()) {.async.} =
      ## Send client response for invalid json state
      let errMsgs = jsonErrorMessages[state]
      await clientTrans.`name`(errMsgs[0], errMsgs[1], id, data)

# Server message processing

proc genProcessMessages(name, sendErrorName, writeCode: NimNode): NimNode =
  let idSendErrJson = newIdentNode($sendErrorName & "Json")
  result = quote do:
    proc `name`[T: RpcClientTransport](server: RpcServer, clientTrans: T,
                        line: string) {.async.} =
      var
        node: JsonNode
        # set up node and/or flag errors
        jsonErrorState = checkJsonErrors(line, node)

      if jsonErrorState.isSome:
        let errState = jsonErrorState.get
        var id =
          if errState.err == rjeInvalidJson or errState.err == rjeNoId:
            newJNull()
          else:
            node["id"]
        await errState.err.`idSendErrJson`(clientTrans, id, %errState.msg)
      else:
        let
          methodName = node["method"].str
          id = node["id"]

        if not server.procs.hasKey(methodName):
          await clientTrans.`sendErrorName`(METHOD_NOT_FOUND, "Method not found", %id,
                                  %(methodName & " is not a registered method."))
        else:
          let callRes = await server.procs[methodName](node["params"])
          var
            value {.inject.} = wrapReply(id, callRes, newJNull())
            client {.inject.}: T
          shallowCopy(client, clientTrans)
          asyncCheck `writeCode`

proc genProcessClient(nameIdent, procMessagesIdent, sendErrIdent, readCode, closeCode: NimNode): NimNode =
  # This generates the processClient proc to match transport.
  # processClient is compatible with createStreamServer and thus StreamCallback.
  # However the constraints are conceptualised so you only need to match it's interface
  # Note: https://github.com/nim-lang/Nim/issues/644
  result = quote do:
    proc `nameIdent`[S: RpcServerTransport, C: RpcClientTransport](server: S, clientTrans: C) {.async, gcsafe.} =
      var rpc = getUserData[RpcServer[S]](server)
      while true:
        var
          client {.inject}: C
          maxRequestLength {.inject.} = defaultMaxRequestLength
        shallowCopy(client, clientTrans)
        let line = await `readCode`
        if line == "":
          `closeCode`
          break

        debug "Processing message", address = clientTrans.remoteAddress(), line = line

        let future = `procMessagesIdent`(rpc, clientTrans, line)
        yield future
        if future.failed:
          if future.readError of RpcProcError:
            let err = future.readError.RpcProcError
            await clientTrans.`sendErrIdent`(err.code, err.msg, err.data)
          elif future.readError of ValueError:
            let err = future.readError[].ValueError
            await clientTrans.`sendErrIdent`(INVALID_PARAMS, err.msg, %"")
          else:
            await clientTrans.`sendErrIdent`(SERVER_ERROR,
                                  "Error: Unknown error occurred", %"")

macro defineRpcTransport*(procClientName: untyped, body: untyped = nil): untyped =
  ## Build an rpcServer type that inlines data access operations
  #[
    Injects:
      client: RpcClientTransport type
      maxRequestLength: optional bytes to read
      value: Json string to be written to transport

    Example:
      defineRpcTransport(myServer):
        write:
          client.write(value)
        read:
          client.readLine(maxRequestLength)
        close:
          client.close
  ]#
  procClientName.expectKind nnkIdent
  var
    writeCode = quote do:
      client.write(value)
    readCode = quote do:
      client.readLine(defaultMaxRequestLength)
    closeCode = quote do:
      client.close

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
        writeCode = item[1]
      of "read":
        readCode = item[1]
      of "close":
        closeCode = item[1]
      else: error("Unknown verb \"" & verb & "\"")
      
  result = newStmtList()

  let
    sendErr = newIdentNode($procClientName & "sendError")
    procMsgs = newIdentNode($procClientName & "processMessages")
  result.add(addErrorSending(sendErr, writeCode))
  result.add(genProcessMessages(procMsgs, sendErr, writeCode))
  result.add(genProcessClient(procClientName, procMsgs, sendErr, readCode, closeCode))
  
  when defined(nimDumpRpcs):
    echo "defineRpc:\n", result.repr

proc start*(server: RpcServer) =
  ## Start the RPC server.
  for item in server.servers:
    item.start()

proc stop*(server: RpcServer) =
  ## Stop the RPC server.
  for item in server.servers:
    item.stop()

proc close*(server: RpcServer) =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    item.close()

# Server registration and RPC generation

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  ## Add a name/code pair to the RPC server.
  server.procs[name] = rpc

proc unRegisterAll*(server: RpcServer) =
  # Remove all remote procedure calls from this server.
  server.procs.clear

proc makeProcName(s: string): string =
  result = ""
  for c in s:
    if c.isAlphaNumeric: result.add c

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and
     params[0].kind != nnkEmpty:
    result = true

macro rpc*(server: RpcServer, path: string, body: untyped): untyped =
  ## Define a remote procedure call.
  ## Input and return parameters are defined using the ``do`` notation.
  ## For example:
  ## .. code-block:: nim
  ##    myServer.rpc("path") do(param1: int, param2: float) -> string:
  ##      result = $param1 & " " & $param2
  ##    ```
  ## Input parameters are automatically marshalled from json to Nim types,
  ## and output parameters are automatically marshalled to json for transport.
  result = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    # all remote calls have a single parameter: `params: JsonNode`
    paramsIdent = newIdentNode"params"
    # procs are generated from the stripped path
    pathStr = $path
    # strip non alphanumeric
    procNameStr = pathStr.makeProcName
    # public rpc proc
    procName = newIdentNode(procNameStr)
    # when parameters present: proc that contains our rpc body
    doMain = newIdentNode(procNameStr & "DoMain")
    # async result
    res = newIdentNode("result")
  var
    setup = jsonToNim(parameters, paramsIdent)
    procBody = if body.kind == nnkStmtList: body else: body.body
    errTrappedBody = quote do:
      try:
        `procBody`
      except:
        debug "Error occurred within RPC ", path = `path`, errorMessage = getCurrentExceptionMsg()
  if parameters.hasReturnType:
    let returnType = parameters[0]

    # delegate async proc allows return and setting of result as native type
    result.add(quote do:
      proc `doMain`(`paramsIdent`: JsonNode): Future[`returnType`] {.async.} =
        `setup`
        `errTrappedBody`
    )

    if returnType == ident"JsonNode":
      # `JsonNode` results don't need conversion
      result.add( quote do:
        proc `procName`(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
          `res` = await `doMain`(`paramsIdent`)
      )
    else:
      result.add(quote do:
        proc `procName`(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
          `res` = %await `doMain`(`paramsIdent`)
      )
  else:
    # no return types, inline contents
    result.add(quote do:
      proc `procName`(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
        `setup`
        `errTrappedBody`
    )
  result.add( quote do:
    `server`.register(`path`, `procName`)
  )

  when defined(nimDumpRpcs):
    echo "\n", pathStr, ": ", result.repr

# Utility functions for setting up servers using stream transport addresses

# Create a default transport that's suitable for createStreamServer
defineRpcTransport(processStreamClient)

proc addStreamServer*[S](server: RpcServer[S], address: TransportAddress, callBack: StreamCallback = processStreamClient) =
  #makeProcessClient(processClient, StreamTransport)
  try:
    info "Creating server on ", address = $address
    var transportServer = createStreamServer(address, callBack, {ReuseAddr}, udata = server)
    server.servers.add(transportServer)
  except:
    error "Failed to create server", address = $address, message = getCurrentExceptionMsg()

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc addStreamServers*[T: RpcServer](server: T, addresses: openarray[TransportAddress], callBack: StreamCallback = processStreamClient) =
  for item in addresses:
    server.addStreamServer(item, callBack)

proc addStreamServer*[T: RpcServer](server: T, address: string, callBack: StreamCallback = processStreamClient) =
  ## Create new server and assign it to addresses ``addresses``.  
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    added = 0

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, IpAddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, IpAddressFamily.IPv6)
  except:
    discard

  for r in tas4:
    server.addStreamServer(r, callBack)
    added.inc
  for r in tas6:
    server.addStreamServer(r, callBack)
    added.inc

  if added == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to get address!")

proc addStreamServers*[T: RpcServer](server: T, addresses: openarray[string], callBack: StreamCallback = processStreamClient) =
  for address in addresses:
    server.addStreamServer(address, callBack)

proc addStreamServer*[T: RpcServer](server: T, address: string, port: Port, callBack: StreamCallback = processStreamClient) =
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    added = 0

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, port, IpAddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, port, IpAddressFamily.IPv6)
  except:
    discard

  if len(tas4) == 0 and len(tas6) == 0:
    # Address was not resolved, critical error.
    raise newException(RpcAddressUnresolvableError,
                       "Address " & address & " could not be resolved!")

  for r in tas4:
    server.addStreamServer(r, callBack)
    added.inc
  for r in tas6:
    server.addStreamServer(r, callBack)
    added.inc

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError,
                      "Could not setup server on " & address & ":" & $int(port))

type RpcStreamServer* = RpcServer[StreamServer]

proc newRpcStreamServer*(addresses: openarray[TransportAddress]): RpcStreamServer = 
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcServer[StreamServer]()
  result.addStreamServers(addresses)

proc newRpcStreamServer*(addresses: openarray[string]): RpcStreamServer =
  ## Create new server and assign it to addresses ``addresses``.  
  result = newRpcServer[StreamServer]()
  result.addStreamServers(addresses)

proc newRpcStreamServer*(address = "localhost", port: Port = Port(8545)): RpcStreamServer =
  # Create server on specified port
  result = newRpcServer[StreamServer]()
  result.addStreamServer(address, port)


# TODO: Allow cross checking between client signatures and server calls
