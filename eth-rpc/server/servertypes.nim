import asyncdispatch, asyncnet, json, tables, macros, strutils
export asyncdispatch, asyncnet, json

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

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  server.procs[name] = rpc

proc unRegisterAll*(server: RpcServer) = server.procs.clear

macro rpc*(prc: untyped): untyped =
  ## Converts a procedure into the following format:
  ##  <proc name>*(params: JsonNode): Future[JsonNode] {.async.}
  ## This procedure is then added into a compile-time list
  ## so that it is automatically registered for every server that
  ## calls registerRpcs(server)
  prc.expectKind nnkProcDef
  result = prc
  let
    params = prc.params
    procName = prc.name

  procName.expectKind(nnkIdent)
  
  # check there isn't already a result type
  assert params[0].kind == nnkEmpty

  # add parameter
  params.add nnkIdentDefs.newTree(
        newIdentNode("params"),
        newIdentNode("JsonNode"),
        newEmptyNode()
      )
  # set result type
  params[0] = nnkBracketExpr.newTree(
    newIdentNode("Future"),
    newIdentNode("JsonNode")
  )
  # add async pragma; we can assume there isn't an existing .async.
  # as this would mean there's a return type and fail the result check above.
  prc.addPragma(newIdentNode("async"))

proc newRpcServer*(address = "localhost", port: Port = Port(8545)): RpcServer =
  result = RpcServer(
    socket: newAsyncSocket(),
    port: port,
    address: address,
    procs: newTable[string, RpcProc]()
  )

var sharedServer: RpcServer

proc sharedRpcServer*(): RpcServer =
  if sharedServer.isNil: sharedServer = newRpcServer("")
  result = sharedServer

macro multiRemove(s: string, values: varargs[string]): untyped =
  ## Wrapper for multiReplace
  var
    body = newStmtList()
    multiReplaceCall = newCall(ident"multiReplace", s)

  body.add(newVarStmt(ident"eStr", newStrLitNode("")))
  let emptyStr = ident"eStr"
  for item in values:
    # generate tuples of values with the empty string `eStr`
    let sItem = $item
    multiReplaceCall.add(newPar(newStrLitNode(sItem), emptyStr))

  body.add multiReplaceCall
  result = newBlockStmt(body)

macro on*(server: var RpcServer, path: string, body: untyped): untyped =
  var paramTemplates = newStmtList()
  let parameters = body.findChild(it.kind == nnkFormalParams)
  if not parameters.isNil:
    # process parameters of body into json fetch templates
    var resType = parameters[0]
    if resType.kind != nnkEmpty:
      # TODO: transform result type and/or return to json
      discard
    #
    for i in 1..<parameters.len:
      parameters[i].expectKind nnkIdentDefs
      #
      let
        name = parameters[i][0]       # take user's parameter name for template
        paramType = parameters[i][1]
      var getFuncName: string
      case $paramType
      of "string": getFuncName = "getStr"
      of "int": getFuncName = "getInt"
      of "float": getFuncName = "getFloat"
      of "bool": getFuncName = "getBool"
      # TODO: array, object
      else: discard
      # fetch parameter 
      let
        getFunc = ident(getFuncName)
        pos = i - 1 # first index is return type
        paramsIdent = ident"params"
      paramTemplates.add(quote do:
        template `name`: `paramType` = `paramsIdent`.elems[`pos`].`getFunc`
      )

  # create RPC proc
  let
    pathStr = $path
    procName = ident(pathStr.multiRemove(".", "/")) # TODO: Make this unique to avoid potential clashes, or allow people to know the name for calling?
    paramsIdent = ident("params")
  var procBody: NimNode
  if body.kind == nnkStmtList: procBody = body
  else: procBody = body.body
  #
  result = quote do:
    proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
      `paramTemplates`
      `procBody`
    `server`.register(`path`, `procName`)

when isMainModule:
  import unittest
  var s = newRpcServer("localhost")
  s.on("the/path") do(a: int, b: string):
    var node = %"test"
    result = node
  s.on("the/path2") do() -> int:
    echo "hello2"
  s.on("the/path3"):
    echo "hello3"
    result = %1
  suite "Server types":
    test "On macro registration":
      check s.procs.hasKey("the/path")
      check s.procs.hasKey("the/path2")
      check s.procs.hasKey("the/path3")
