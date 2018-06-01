import asyncdispatch, asyncnet, json, tables, macros, strutils, ../ jsonmarshal
export asyncdispatch, asyncnet, json, jsonmarshal

type
  RpcProc* = proc (params: JsonNode): Future[JsonNode]

  RpcServer* = ref object
    socket*: AsyncSocket
    port*: Port
    address*: string
    procs*: TableRef[string, RpcProc]

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

var sharedServer: RpcServer

proc newRpcServer*(address = "localhost", port: Port = Port(8545)): RpcServer =
  result = RpcServer(
    socket: newAsyncSocket(),
    port: port,
    address: address,
    procs: newTable[string, RpcProc]()
  )

proc sharedRpcServer*(): RpcServer =
  if sharedServer.isNil: sharedServer = newRpcServer("")
  result = sharedServer

proc `$`*(port: Port): string = $int(port)

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
  ## Register RPC using the proc itself, and the string of it's name for the path.
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

proc unRegisterAll*(server: RpcServer) = server.procs.clear

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and params[0].kind != nnkEmpty:
    result = true

proc rpcInternal(procNameStr: string, body: NimNode): NimNode =
  result = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    paramsIdent = newIdentNode"params"            # all remote calls have a single parameter: `params: JsonNode`  
    procName = newIdentNode(procNameStr)          # public rpc proc
    doMain = newIdentNode(procNameStr & "DoMain") # when parameters present: proc that contains our rpc body
    res = newIdentNode("result")                  # async result
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
  ## Constructs an async marshalling wrapper proc around `body` and registers it with `server`.
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
  ## Constructs an async marshalling wrapper proc around body with a generated name, which is returned 
  let
    name = genSym(nskProc)
    procName = $name
  result = rpcInternal(procName, body)
  result.add(quote do:
    `procName`
    )
  when defined(nimDumpRpcs):
    echo "\n", procName, ": ", result.repr

# TODO: Allow cross checking between client signatures and server calls

when isMainModule:
  var srv = newRpcServer()

  # Creating RPCs without registering
  rpc("a.b"):
    discard
  rpc("b.c"):
    discard

  # Create an RPC with a generated name
  let procname = rpc():
    discard
  echo "Generated name: ", procName

  # Creates an RPC and registers it with the server
  srv.registerRpc("d"):
    discard

  # Register using vararg path names
  srv.register("a.b", "b.c")
  # Register using symbol
  srv.register(procName)
  # Register using array of symbols
  srv.register([ab, bc, d])

