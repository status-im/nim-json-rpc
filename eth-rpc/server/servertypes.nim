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
  
proc fromJson(n: JsonNode, argName: string, result: var bool) =
  if n.kind != JBool: raise newException(ValueError, "Parameter \"" & argName & "\" expected JBool but got " & $n.kind)
  result = n.getBool()

proc fromJson(n: JsonNode, argName: string, result: var int) =
  if n.kind != JInt: raise newException(ValueError, "Parameter \"" & argName & "\" expected JInt but got " & $n.kind)
  result = n.getInt()

proc fromJson(n: JsonNode, argName: string, result: var byte) =
  if n.kind != JInt: raise newException(ValueError, "Parameter \"" & argName & "\" expected JInt but got " & $n.kind)
  let v = n.getInt()
  if v > 255 or v < 0: raise newException(ValueError, "Parameter \"" & argName & "\" value out of range for byte: " & $v)
  result = byte(v)

proc fromJson(n: JsonNode, argName: string, result: var float) =
  if n.kind != JFloat: raise newException(ValueError, "Parameter \"" & argName & "\" expected JFloat but got " & $n.kind)
  result = n.getFloat()

proc fromJson(n: JsonNode, argName: string, result: var string) =
  if n.kind != JString: raise newException(ValueError, "Parameter \"" & argName & "\" expected JString but got " & $n.kind)
  result = n.getStr()

proc fromJson[T](n: JsonNode, argName: string, result: var seq[T]) =
  if n.kind != JArray: raise newException(ValueError, "Parameter \"" & argName & "\" expected JArray but got " & $n.kind)
  result = newSeq[T](n.len)
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T]) =
  if n.kind != JArray: raise newException(ValueError, "Parameter \"" & argName & "\" expected JArray but got " & $n.kind)
  if n.len > result.len: raise newException(ValueError, "Parameter \"" & argName & "\" item count is too big for array")
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc fromJson[T: object](n: JsonNode, argName: string, result: var T) =
  if n.kind != JObject: raise newException(ValueError, "Parameter \"" & argName & "\" expected JObject but got " & $n.kind)
  for k, v in fieldpairs(result):
    fromJson(n[k], k, v)

proc unpackArg[T](argIdx: int, argName: string, argtype: typedesc[T], args: JsonNode): T =
  fromJson(args[argIdx], argName, result)

proc setupParams(parameters, paramsIdent: NimNode): NimNode =
  # Add code to verify input and load parameters into Nim types
  result = newStmtList()
  if not parameters.isNil:
    # initial parameter array length check
    var expectedLen = parameters.len - 1
    let expectedStr = "Expected " & $expectedLen & " Json parameter(s) but got "
    result.add(quote do:
      if `paramsIdent`.kind != JArray:
        raise newException(ValueError, "Parameter params expected JArray but got " & $`paramsIdent`.kind)
      if `paramsIdent`.len != `expectedLen`:
        raise newException(ValueError, `expectedStr` & $`paramsIdent`.len)
    )
    # unpack each parameter and provide assignments
    for i in 1 ..< parameters.len:
      let
        paramName = parameters[i][0]
        pos = i - 1
        paramNameStr = $paramName
        paramType = parameters[i][1]
      result.add(quote do:
        var `paramName` = `unpackArg`(`pos`, `paramNameStr`, `paramType`, `paramsIdent`)
      )
  else:
    # no parameters expected
    result.add(quote do:
      if `paramsIdent`.len != 0:
        raise newException(ValueError, "Expected no parameters but got " & $`paramsIdent`.len)
    )


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
  result = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    paramsIdent = ident"params"  
  var setup = setupParams(parameters, paramsIdent)

  # wrapping proc
  let
    pathStr = $path
    procName = ident(pathStr.multiRemove(".", "/")) # TODO: Make this unique to avoid potential clashes, or allow people to know the name for calling?
  var procBody: NimNode
  if body.kind == nnkStmtList: procBody = body
  else: procBody = body.body
  result = quote do:
    proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
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
  let
    testObj = %*{
      "a": %1,
      "b": %*{
        "a": %[5, 0],
        "b": %*{
          "x": %[1, 2, 3],
          "y": %"test"
        }
      },
      "c": %1.23}

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
      let r = waitfor rpcObjParam(%[%"abc", testObj])
      check r == testObj
    test "Runtime errors":
      expect ValueError:
        echo waitfor rpcArrayParam(%[%[0, 1, 2, 3, 4, 5, 6], %"hello"])


