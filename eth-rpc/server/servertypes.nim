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
    pathStr = $path
    procName = ident(pathStr.multiRemove(".", "/"))
  var
    setup = setupParams(parameters, paramsIdent)
    procBody: NimNode
  if body.kind == nnkStmtList: procBody = body
  else: procBody = body.body
  
  # wrapping async proc
  result = quote do:
    proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
      `setup`
      `procBody`
    `server`.register(`path`, `procName`)
  when defined(nimDumpRpcs):
    echo "\n", pathStr, ": ", result.repr
