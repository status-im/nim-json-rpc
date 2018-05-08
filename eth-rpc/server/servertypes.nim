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

proc preParseTypes(typeNode: var NimNode, typeName: NimNode, errorCheck: var NimNode): bool {.compileTime.} =
  # handle byte
  for i, item in typeNode:
    if item.kind == nnkIdent and item.basename == ident"byte":
      typeNode[i] = ident"int"
      # add some extra checks
      result = true
    else:
      var t = typeNode[i]
      if preParseTypes(t, typeName, errorCheck):
        typeNode[i] = t

proc expect(node, jsonIdent, fieldName: NimNode, tn: JsonNodeKind) =
  let
    expectedStr = "Expected parameter `" & fieldName.repr & "` to be " & $tn & " but got "
    tnIdent = ident($tn)
  node.add(quote do:
    if `jsonIdent`.kind != `tnIdent`:
      raise newException(ValueError, `expectedStr` & $`jsonIdent`.kind)
  )
  
###

proc fromJson(n: JsonNode, result: var int) =
  # TODO: validate...
  result = n.getInt()

proc fromJson(n: JsonNode, result: var byte) =
  let v = n.getInt()
  if v > 255: raise newException(ValueError, "Parameter value to large for byte: " & $v)
  result = byte(v)

proc fromJson(n: JsonNode, result: var float) =
  # TODO: validate...
  result = n.getFloat()

proc fromJson(n: JsonNode, result: var string) =
  # TODO: validate...
  result = n.getStr()

proc fromJson[T](n: JsonNode, result: var seq[T]) =
  # TODO: validate...
  result = newSeq[T](n.len)
  for i in 0 ..< n.len:
    fromJson(n[i], result[i])

proc fromJson[N, T](n: JsonNode, result: var array[N, T]) =
  # TODO: validate...
  if n.len > result.len: raise newException(ValueError, "Parameter data too big for array")
  for i in 0..< n.len:
    fromJson(n[i], result[i])

proc fromJson[T: object](n: JsonNode, result: var T) = # This reads a custom object
  # TODO: validate...
  for k, v in fieldpairs(result):
    fromJson(n[k], v)

proc unpackArg[T](argIdx: int, argName: string, argtype: typedesc[T], args: JsonNode): T =
  echo argName, " ", args.pretty
  fromJson(args[argIdx], result)

proc setupParams(node, parameters, paramsIdent: NimNode) =
  # recurse parameter's fields until we only have symbols
  if not parameters.isNil:
    var
      errorCheck = newStmtList()
      expectedParams = parameters.len - 1
    let expectedStr = "Expected " & $`expectedParams` & " Json parameter(s) but got "
    node.add(quote do:
      if `paramsIdent`.len != `expectedParams`:
        raise newException(ValueError, `expectedStr` & $`paramsIdent`.len)
    )

    for i in 1 ..< parameters.len:
      let
        paramName = parameters[i][0]
        pos = i - 1
        paramNameStr = $paramName
      var
        paramType = parameters[i][1]
      node.add(quote do:
        var `paramName` = `unpackArg`(`pos`, `paramNameStr`, `paramType`, `paramsIdent`)
        
        `errorCheck`
      )

macro on*(server: var RpcServer, path: string, body: untyped): untyped =
  result = newStmtList()
  var setup = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    paramsIdent = ident"params"  
  setup.setupParams(parameters, paramsIdent)

  # wrapping proc
  let
    pathStr = $path
    procName = ident(pathStr.multiRemove(".", "/")) # TODO: Make this unique to avoid potential clashes, or allow people to know the name for calling?
  var procBody: NimNode
  if body.kind == nnkStmtList: procBody = body
  else: procBody = body.body
  result = quote do:
    proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
      #`checkTypeError`
      `setup`
      `procBody`
    `server`.register(`path`, `procName`)
  when defined(nimDumpRpcs):
    echo pathStr, ": ", result.repr

when isMainModule:
  import unittest
  var s = newRpcServer("localhost")
  s.on("rpc.simplepath"):
    result = %1
  s.on("rpc.returnint") do() -> int:
    result = %2
  s.on("rpc.differentparams") do(a: int, b: string):
    var node = %"test"
    result = node
  s.on("rpc.arrayparam") do(arr: array[0..5, byte], b: string):
    var res = newJArray()
    for item in arr:
      res.add %int(item)
    res.add %b
    result = %res
  s.on("rpc.seqparam") do(a: string, s: seq[int]):
    var res = newJArray()
    res.add %a
    for item in s:
      res.add %int(item)
    result = res

  type
    Test2 = object
      x: array[0..2, int]
      y: string

    Test = object
      a: array[0..1, int]
      b: Test2

    MyObject* = object
      a: int
      b: Test
      c: float

  s.on("rpc.objparam") do(a: string, obj: MyObject):
    result = %obj
  suite "Server types":
    test "On macro registration":
      check s.procs.hasKey("rpc.simplepath")
      check s.procs.hasKey("rpc.returnint")
      check s.procs.hasKey("rpc.returnint")
    test "Array/seq parameters":
      let r1 = waitfor rpcArrayParam(%[%[1, 2, 3], %"hello"])
      var ckR1 = %[1, 2, 3, 0, 0, 0]
      ckR1.elems.add %"hello"
      check r1 == ckR1

      let r2 = waitfor rpcSeqParam(%[%"abc", %[1, 2, 3, 4, 5]])
      var ckR2 = %["abc"]
      for i in 0..4: ckR2.add %(i + 1)
      check r2 == ckR2
    test "Object parameters":
      let
        obj = %*{
          "a": %1,
          "b": %*{
            "a": %[5, 0],
            "b": %*{
              "x": %[1, 2, 3],
              "y": %"test"
            }
          },
          "c": %1.23}
        r = waitfor rpcObjParam(%[%"abc", obj])
      check r == obj
    test "Runtime errors":
      expect ValueError:
        echo waitfor rpcArrayParam(%[%[0, 1, 2, 3, 4, 5, 6], %"hello"])


