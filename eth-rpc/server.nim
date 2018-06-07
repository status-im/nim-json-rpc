import json, tables, strutils, options, macros
import asyncdispatch2
import jsonmarshal

export asyncdispatch2, json, jsonmarshal

type
  RpcJsonError* = enum rjeInvalidJson, rjeVersionError, rjeNoMethod, rjeNoId

  RpcJsonErrorContainer* = tuple[err: RpcJsonError, msg: string]

  # Procedure signature accepted as an RPC call by server
  RpcProc* = proc (params: JsonNode): Future[JsonNode]

  RpcServer* = ref object of RootRef
    servers*: seq[StreamServer]
    procs*: TableRef[string, RpcProc]

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

const
  JSON_PARSE_ERROR* = -32700
  INVALID_REQUEST* = -32600
  METHOD_NOT_FOUND* = -32601
  INVALID_PARAMS* = -32602
  INTERNAL_ERROR* = -32603
  SERVER_ERROR* = -32000

  jsonErrorMessages*: array[RpcJsonError, (int, string)] =
    [
      (JSON_PARSE_ERROR, "Invalid JSON"),
      (INVALID_REQUEST, "JSON 2.0 required"),
      (INVALID_REQUEST, "No method requested"),
      (INVALID_REQUEST, "No id specified")
    ]

when not defined(release):
  template ifDebug*(actions: untyped): untyped =
    actions
else:
  template ifDebug*(actions: untyped): untyped =
    discard

proc `$`*(port: Port): string = $int(port)

# Json state checking

template jsonValid*(jsonString: string, node: var JsonNode): (bool, string) =
  var
    valid = true
    msg = ""
  try: node = parseJson(line)
  except:
    valid = false
    msg = getCurrentExceptionMsg()
  (valid, msg)

proc checkJsonErrors*(line: string,
                      node: var JsonNode): Option[RpcJsonErrorContainer] =
  ## Tries parsing line into node, if successful checks required fields
  ## Returns: error state or none
  let res = jsonValid(line, node)
  if not res[0]:
    return some((rjeInvalidJson, res[1]))
  if not node.hasKey("jsonrpc"):
    return some((rjeVersionError, ""))
  if not node.hasKey("method"):
    return some((rjeNoMethod, ""))
  if not node.hasKey("id"):
    return some((rjeNoId, ""))
  return none(RpcJsonErrorContainer)

# Json reply wrappers

proc wrapReply*(id: JsonNode, value: JsonNode, error: JsonNode): string =
  let node = %{"jsonrpc": %"2.0", "result": value, "error": error, "id": id}
  return $node & "\c\l"

proc sendError*(client: StreamTransport, code: int, msg: string, id: JsonNode,
                data: JsonNode = newJNull()) {.async.} =
  ## Send error message to client
  let error = %{"code": %(code), "message": %msg, "data": data}
  ifDebug: echo "Send error json: ", wrapReply(newJNull(), error, id)
  result = client.write(wrapReply(id, newJNull(), error))

proc sendJsonError*(state: RpcJsonError, client: StreamTransport, id: JsonNode,
                    data = newJNull()) {.async.} =
  ## Send client response for invalid json state
  let errMsgs = jsonErrorMessages[state]
  await client.sendError(errMsgs[0], errMsgs[1], id, data)

# Server message processing
proc processMessage(server: RpcServer, client: StreamTransport,
                    line: string) {.async.} =
  var
    node: JsonNode
    # set up node and/or flag errors
    jsonErrorState = checkJsonErrors(line, node)
  if jsonErrorState.isSome:
    let errState = jsonErrorState.get
    var id = if errState.err == rjeInvalidJson: newJNull() else: node["id"]
    await errState.err.sendJsonError(client, id, %errState.msg)
  else:
    let
      methodName = node["method"].str
      id = node["id"]

    if not server.procs.hasKey(methodName):
      await client.sendError(METHOD_NOT_FOUND, "Method not found", id,
                                 %(methodName & " is not a registered method."))
    else:
      let callRes = await server.procs[methodName](node["params"])
      discard await client.write(wrapReply(id, callRes, newJNull()))

proc processClient(server: StreamServer, client: StreamTransport) {.async.} =
  var rpc = getUserData[RpcServer](server)
  while true:
    ## TODO: We need to put limit here, or server could be easily put out of
    ## service without never-ending line (data without CRLF).
    let line = await client.readLine()
    if line == "":
      client.close()
      break

    ifDebug: echo "Process client: ", client.remoteAddress()

    let future = processMessage(rpc, client, line)
    yield future
    if future.failed:
      if future.readError of RpcProcError:
        let err = future.readError.RpcProcError
        await client.sendError(err.code, err.msg, err.data)
      elif future.readError of ValueError:
        let err = future.readError[].ValueError
        await client.sendError(INVALID_PARAMS, err.msg, %"")
      else:
        await client.sendError(SERVER_ERROR,
                               "Error: Unknown error occurred", %"")

proc newRpcServer*(address = "localhost", port: Port = Port(8545)): RpcServer =
  let tas4 = resolveTAddress(address, port, IpAddressFamily.IPv4)
  let tas6 = resolveTAddress(address, port, IpAddressFamily.IPv6)
  result = RpcServer()
  result.procs = newTable[string, RpcProc]()
  result.servers = newSeq[StreamServer]()
  for item in tas4:
    ifDebug: echo "Create server on " & $item
    var server = createStreamServer(item, processClient, {ReuseAddr},
                                    udata = result)
    result.servers.add(server)
  for item in tas6:
    ifDebug: echo "Create server on " & $item
    var server = createStreamServer(item, processClient, {ReuseAddr},
                                    udata = result)
    result.servers.add(server)

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

  if parameters.hasReturnType:
    let returnType = parameters[0]

    # delegate async proc allows return and setting of result as native type
    result.add(quote do:
      proc `doMain`(`paramsIdent`: JsonNode): Future[`returnType`] {.async.} =
        `setup`
        `procBody`
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
        `procBody`
    )
  result.add( quote do:
    `server`.register(`path`, `procName`)
  )

  when defined(nimDumpRpcs):
    echo "\n", pathStr, ": ", result.repr

# TODO: Allow cross checking between client signatures and server calls
