import asyncdispatch, asyncnet, json, tables, macros, strutils, jsonconverters, stint
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

proc `$`*(port: Port): string = $int(port)
  
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
proc fromJson(n: JsonNode, argName: string, result: var byte)
proc fromJson(n: JsonNode, argName: string, result: var float)
proc fromJson(n: JsonNode, argName: string, result: var string)
proc fromJson[T](n: JsonNode, argName: string, result: var seq[T])
proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T])
proc fromJson(n: JsonNode, argName: string, result: var UInt256)

# TODO: Why can't this be forward declared? Complains of lack of definition
proc fromJson[T: enum](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JInt, argName)
  result = n.getInt().T

# TODO: Why can't this be forward declared? Complains of lack of definition
proc fromJson[T: object](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JObject, argName)
  for k, v in fieldpairs(result):
    fromJson(n[k], k, v)

proc fromJson(n: JsonNode, argName: string, result: var int64) =
  n.kind.expect(JInt, argName)
  result = n.getInt()

proc fromJson(n: JsonNode, argName: string, result: var byte) =
  n.kind.expect(JInt, argName)
  let v = n.getInt()
  if v > 255 or v < 0: raise newException(ValueError, "Parameter \"" & argName & "\" value out of range for byte: " & $v)
  result = byte(v)

proc fromJson(n: JsonNode, argName: string, result: var UInt256) =
  # expects base 16 string, starting with "0x"
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if hexStr.len > 64 + 2: # including "0x"
    raise newException(ValueError, "Parameter \"" & argName & "\" value too long for UInt256: " & $hexStr.len)
  result = hexStr.parse(StUint[256], 16) # TODO: Handle errors

proc fromJson(n: JsonNode, argName: string, result: var float) =
  n.kind.expect(JFloat, argName)
  result = n.getFloat()

proc fromJson(n: JsonNode, argName: string, result: var string) =
  n.kind.expect(JString, argName)
  result = n.getStr()

proc fromJson[T](n: JsonNode, argName: string, result: var seq[T]) =
  n.kind.expect(JArray, argName)
  result = newSeq[T](n.len)
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T]) =
  n.kind.expect(JArray, argName)
  if n.len > result.len: raise newException(ValueError, "Parameter \"" & argName & "\" item count is too big for array")
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc unpackArg[T](args: JsonNode, argIdx: int, argName: string, argtype: typedesc[T]): T =
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
        var `paramName` = `unpackArg`(`paramsIdent`, `pos`, `paramNameStr`, type(`paramType`))
      )

proc makeProcName(s: string): string =
  # only alphanumeric
  result = ""
  for c in s:
    if c.isAlphaNumeric: result.add c

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and params[0].kind != nnkEmpty:
    result = true

macro rpc*(server: var RpcServer, path: string, body: untyped): untyped =
  result = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    paramsIdent = newIdentNode"params"            # all remote calls have a single parameter: `params: JsonNode`  
    pathStr = $path                               # procs are generated from the stripped path
    procNameStr = pathStr.makeProcName            # strip non alphanumeric
    procName = newIdentNode(procNameStr)          # public rpc proc
    doMain = newIdentNode(procNameStr & "DoMain") # when parameters: proc that contains our rpc body
    res = newIdentNode("result")                  # async result
  var
    setup = setupParams(parameters, paramsIdent)
    procBody = if body.kind == nnkStmtList: body else: body.body

  if parameters.hasReturnType:
    let returnType = parameters[0]

    # delgate async proc allows return and setting of result as native type
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
  result.add( quote do:
    `server`.register(`path`, `procName`)
  )

  when defined(nimDumpRpcs):
    echo "\n", pathStr, ": ", result.repr
