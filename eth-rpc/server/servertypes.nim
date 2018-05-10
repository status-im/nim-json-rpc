import asyncdispatch, asyncnet, json, tables, macros, strutils, jsonconverters
export asyncdispatch, asyncnet, json, jsonconverters

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
  
template expect*(actual, expected: JsonNodeKind, argName: string) =
  if actual != expected: raise newException(ValueError, "Parameter \"" & argName & "\" expected " & $expected & " but got " & $actual)

proc fromJson(n: JsonNode, argName: string, result: var bool) =
  n.kind.expect(JBool, argName)
  result = n.getBool()

proc fromJson(n: JsonNode, argName: string, result: var int) =
  n.kind.expect(JInt, argName)
  result = n.getInt()

# TODO: Why does compiler complain that result cannot be assigned to when using result: var int|var int64
# TODO: Compiler requires forward decl when processing out of module
proc fromJson(n: JsonNode, argName: string, result: var uint64)
proc fromJson(n: JsonNode, argName: string, result: var byte)
proc fromJson(n: JsonNode, argName: string, result: var float)
proc fromJson(n: JsonNode, argName: string, result: var string)
proc fromJson[T](n: JsonNode, argName: string, result: var seq[T])
proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T])

# TODO: Why can't this be forward declared? Complains of lack of definition
proc fromJson[T: enum](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JInt, argName)
  result = n.getInt().T

# TODO: Why can't this be forward declared? Complains of lack of definition
proc fromJson[T: object](n: JsonNode, argName: string, result: var T) =
  for k, v in fieldpairs(result):
    fromJson(n[k], k, v)

proc fromJson(n: JsonNode, argName: string, result: var int64) =
  n.kind.expect(JInt, argName)
  result = n.getInt()

proc fromJson(n: JsonNode, argName: string, result: var uint64) =
  n.kind.expect(JInt, argName)
  result = n.getInt().uint64

proc fromJson(n: JsonNode, argName: string, result: var byte) =
  n.kind.expect(JInt, argName)
  let v = n.getInt()
  if v > 255 or v < 0: raise newException(ValueError, "Parameter \"" & argName & "\" value out of range for byte: " & $v)
  result = byte(v)

# TODO: Alow string input for UInt256?
#[
proc fromJson(n: JsonNode, argName: string, result: var UInt256) =
  n.kind.expect(JString, argName)
  result = n.getStr().parse(Stint[256]) # TODO: Requires error checking?
]#

proc fromJson(n: JsonNode, argName: string, result: var float) =
  n.kind.expect(JFloat, argName)
  result = n.getFloat()

proc fromJson(n: JsonNode, argName: string, result: var string) =
  n.kind.expect(JString, argName)
  result = n.getStr()

proc fromJson[T](n: JsonNode, argName: string, result: var seq[T]) =
  result = newSeq[T](n.len)
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T]) =
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc unpackArg[T](argIdx: int, argName: string, argtype: typedesc[T], args: JsonNode): T =
  when argType is array or argType is seq:
    args[argIdx].kind.expect(JArray, argName)
  when argType is array:
    if args[argIdx].len > result.len: raise newException(ValueError, "Parameter \"" & argName & "\" item count is too big for array")
  when argType is object:
    args[argIdx].kind.expect(JObject, argName)
  fromJson(args[argIdx], argName, result)

proc expectArrayLen(node: NimNode, paramsIdent: untyped, length: int) =
  let
    identStr = paramsIdent.repr
    expectedStr = "Expected " & $length & " Json parameter(s) but got "
  node.add(quote do:
    `paramsIdent`.kind.expect(JArray, `identStr`)
    if `paramsIdent`.len != `length`:
      raise newException(ValueError, `expectedStr` & $`paramsIdent`.len)
  )

proc setupParams(parameters, paramsIdent: NimNode): NimNode =
  # Add code to verify input and load parameters into Nim types
  result = newStmtList()
  if not parameters.isNil:
    # initial parameter array length check
    result.expectArrayLen(paramsIdent, parameters.len - 1)
    # unpack each parameter and provide assignments
    for i in 1 ..< parameters.len:
      let
        pos = i - 1
        paramName = parameters[i][0]
        paramNameStr = $paramName
        paramType = parameters[i][1]
      result.add(quote do:
        var `paramName` = `unpackArg`(`pos`, `paramNameStr`, `paramType`, `paramsIdent`)
      )

proc makeProcName(s: string): string =
  s.multiReplace((".", ""), ("/", ""))

macro on*(server: var RpcServer, path: string, body: untyped): untyped =
  result = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    paramsIdent = ident"params"  
    pathStr = $path
    procName = ident(pathStr.makeProcName)
  var
    setup = setupParams(parameters, paramsIdent)
    procBody: NimNode
    bodyWrapper = newStmtList()

  if body.kind == nnkStmtList: procBody = body
  else: procBody = body.body

  if parameters.len > 0 and parameters[0] != nil and parameters[0] != ident"JsonNode":
    # when a return type is specified, shadow async's result
    # and pass it back jsonified - of course, we don't want to do this
    # if a JsonNode is explicitly declared as the return type     
    let
      returnType = parameters[0]
      res = ident"result"
    template doMain(body: untyped): untyped =
      # create a new scope to allow shadowing result
      block:
        body
    bodyWrapper = quote do:
      `res` = `doMain`:
        var `res`: `returnType`
        `procBody`
        %`res`
  else:
    bodyWrapper = quote do: `procBody`
    
  # async proc wrapper around body
  result = quote do:
      proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
        `setup`
        `bodyWrapper`
      `server`.register(`path`, `procName`)
  when defined(nimDumpRpcs):
    echo "\n", pathStr, ": ", result.repr
