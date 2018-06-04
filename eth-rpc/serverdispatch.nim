import json, tables, strutils, options, macros
import asyncdispatch2
import jsonmarshal

export json, jsonmarshal

type
  RpcJsonError* = enum
    rjeInvalidJson, rjeVersionError, rjeNoMethod, rjeNoId

  RpcJsonErrorContainer* = tuple[err: RpcJsonError, msg: string]

  RpcProc* = proc (params: JsonNode): Future[JsonNode]

  RpcServer* = ref object of RootRef
    server*: StreamServer
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
  template ifDebug*(actions: untyped): untyped = discard

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

proc wrapReply*(id: JsonNode, value: JsonNode, error: JsonNode): JsonNode =
  return %{"jsonrpc": %"2.0", "result": value, "error": error, "id": id}

proc sendError*(client: StreamTransport, code: int, msg: string,
                id: JsonNode, data: JsonNode = newJNull()) {.async.} =
  ## Send error message to client
  let error = %{"code": %(code), "message": %msg, "data": data}
  ifDebug: echo "Send error json: ",
                wrapReply(newJNull(), error, id).pretty & "\c\l"
  var answer = $wrapReply(id, newJNull(), error)
  answer.add("\c\l")
  result = client.write(addr answer[0], len(answer))

proc sendJsonError*(state: RpcJsonError, client: StreamTransport,
                    id: JsonNode, data = newJNull()) {.async.} =
  ## Send client response for invalid json state
  let errMsgs = jsonErrorMessages[state]
  await client.sendError(errMsgs[0], errMsgs[1], id, data)

proc processMessage(server: RpcServer, client: StreamTransport,
                    line: string) {.async.} =
  var node, id: JsonNode
  # set up node and/or flag errors
  var jsonErrorState = checkJsonErrors(line, node)

  if jsonErrorState.isSome:
    let errState = jsonErrorState.get
    if errState.err == rjeInvalidJson:
      # id cannot be retrieved
      id = newJNull()
    else:
      id = if "id" in node: node["id"] else: newJNull()
    await errState.err.sendJsonError(client, id, %errState.msg)
  else:
    let methodName = node["method"].str
    id = node["id"]

    if not server.procs.hasKey(methodName):
      await client.sendError(METHOD_NOT_FOUND, "Method not found", id,
                             %(methodName & " is not a registered method."))
    else:
      let res = await server.procs[methodName](node["params"])
      var answer = $wrapReply(id, res, newJNull())
      answer.add("\c\l")
      discard await client.write(cast[pointer](addr answer[0]), len(answer))

proc processClient(server: StreamServer,
                   client: StreamTransport, udata: pointer) {.async.} =

  while true:
    let line = await client.readLine(limit = 1024)
    if len(line) == 0:
      client.close()
      break

    ifDebug: echo "Process client: ", $client.remoteAddress, ":" & line
    var rpcsrv = cast[RpcServer](udata)
    var fut = processMessage(rpcsrv, client, line)
    yield fut
    if fut.failed:
      let err = fut.readError
      if err of RpcProcError:
        let rpcerr = RpcProcError(err)
        await client.sendError(rpcerr.code, rpcerr.msg, rpcerr.data)
      else:
        await client.sendError(SERVER_ERROR, "Error", %getCurrentExceptionMsg())

proc newRpcServer*(address: TransportAddress): RpcServer =
  ## Create new instance of RPC server.
  result = RpcServer(procs: newTable[string, RpcProc]())
  result.server = createStreamServer(address, processClient, {ReuseAddr},
                                     udata = cast[pointer](result))

proc newRpcServer*(address: string, port: Port): RpcServer =
  ## Create new instance of RPC server.
  result = RpcServer(procs: newTable[string, RpcProc]())
  var ta = resolveTAddress(address & ":" & $int(port))
  result.server = createStreamServer(ta[0], processClient, {ReuseAddr},
                                     udata = cast[pointer](result))

proc start*(server: RpcServer) =
  ## Start RPC server.
  server.server.start()

proc stop*(server: RpcServer) =
  ## Stop RPC server.
  server.server.stop()

proc pause*(server: RpcServer) =
  ## Pause RPC server.
  server.server.pause()

proc join*(server: RpcServer) {.async.} =
  ## Wait until RPC server online.
  await server.server.join()

proc close*(server: RpcServer) =
  ## Close RPC server.
  server.server.close()

proc makeProcName(s: string): string =
  result = ""
  for c in s:
    if c.isAlphaNumeric: result.add c

proc register*(server: RpcServer, path: string, rpc: RpcProc) =
  ## Register RPC with path name and procedure.
  server.procs[path] = rpc

macro register*(server: RpcServer, paths: varargs[string]): untyped =
  ## Register RPCs using a string of the procedure name.
  ## Note that the paths are added verbatim to the server,
  ## but procedures are found by stripping non-alphanumeric characters.
  result = newStmtList()
  for item in paths:
    let
      path = $item
      procName = path.makeProcName
      procIdent = newIdentNode(procName)
    result.add(quote do:
      `server`.register(`path`, `procIdent`)
    )

macro register*(server: RpcServer, procs: untyped): untyped =
  ## Register RPC using the proc itself, and the string of it's name for
  ## the path.
  result = newStmtList()
  const allowedKinds = {nnkBracket, nnkSym}
  if procs.kind notin allowedKinds:
    error("Expected " & $allowedKinds & ", got " & $procs.kind, procs)
  for item in procs:
    item.expectKind nnkSym
    let
      s = $item
      rpcProc = newIdentNode(s)
    result.add(quote do:
      `server`.register(`s`, `rpcProc`)
    )

proc unRegisterAll*(server: RpcServer) =
  ## Unregister all registered RPC from ``server``.
  server.procs.clear

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and
     params[0].kind != nnkEmpty:
    result = true

proc rpcInternal(procNameStr: string, body: NimNode): NimNode =
  result = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    # all remote calls have a single parameter: `params: JsonNode`
    paramsIdent = newIdentNode"params"
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
        proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
          `res` = await `doMain`(`paramsIdent`)
      )
    else:
      result.add(quote do:
        proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
          `res` = %await `doMain`(`paramsIdent`)
      )
  else:
    # no return types, inline contents
    result.add(quote do:
      proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
        `setup`
        `procBody`
    )

macro registerRpc*(server: RpcServer, path: string, body: untyped): untyped =
  ## Constructs an async marshalling wrapper proc around `body` and registers
  ## it with `server`.
  let
    procPath = $path
    procName = procPath.makeProcName
    rpc = newIdentNode(procName)
  result = rpcInternal(procName, body)
  result.add(quote do:
    `server`.register(`procPath`, `rpc`)
    )
  when defined(nimDumpRpcs):
    echo "\nUnnamed RPC ", procName, ": ", result.repr

macro rpc*(path: string, body: untyped): untyped =
  ## Constructs an async marshalling wrapper proc around body.
  let procName = ($path).makeProcName
  result = rpcInternal(procName, body)
  when defined(nimDumpRpcs):
    echo "\n", procName, ": ", result.repr

macro rpc*(body: untyped): untyped =
  ## Constructs an async marshalling wrapper proc around body with a generated
  ## name, which is returned
  let
    name = genSym(nskProc)
    procName = $name
  result = rpcInternal(procName, body)
  result.add(quote do:
    `procName`
    )
  when defined(nimDumpRpcs):
    echo "\n", procName, ": ", result.repr
