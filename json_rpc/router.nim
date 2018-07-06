import json, tables, asyncdispatch2, jsonmarshal, strutils, macros
export asyncdispatch2, json, jsonmarshal

type
  # Procedure signature accepted as an RPC call by server
  RpcProc* = proc(input: JsonNode): Future[JsonNode]

  RpcRouter* = object
    procs*: TableRef[string, RpcProc]
  
const
  methodField = "method"
  paramsField = "params"

proc newRpcRouter*: RpcRouter =
  result.procs = newTable[string, RpcProc]()

proc register*(router: var RpcRouter, path: string, call: RpcProc) =
  router.procs.add(path, call)

proc clear*(router: var RpcRouter) = router.procs.clear

proc hasMethod*(router: RpcRouter, methodName: string): bool = router.procs.hasKey(methodName)

template isEmpty(node: JsonNode): bool = node.isNil or node.kind == JNull

proc route*(router: RpcRouter, data: JsonNode): Future[JsonNode] {.async, gcsafe.} =
  ## Route to RPC, raises exceptions on missing data
  let jPath = data{methodField}
  if jPath.isEmpty:
    raise newException(ValueError, "No " & methodField & " field found")

  let jParams = data{paramsField}
  if jParams.isEmpty:
    raise newException(ValueError, "No " & paramsField & " field found")

  let
    path = jPath.getStr
    rpc = router.procs.getOrDefault(path)
  # TODO: not GC-safe as it accesses 'rpc' which is a global using GC'ed memory!
  if rpc != nil:
    result = await rpc(jParams)
  else:
    raise newException(ValueError, "Method \"" & path & "\" not found")

proc ifRoute*(router: RpcRouter, data: JsonNode, fut: var Future[JsonNode]): bool =
  ## Route to RPC, returns false if the method or params cannot be found
  # TODO: This is already checked in processMessages, but allows safer use externally
  let
    jPath = data{methodField}
    jParams = data{paramsField}
  if jPath.isEmpty or jParams.isEmpty:
    return false

  let
    path = jPath.getStr
    rpc = router.procs.getOrDefault(path)
  if rpc != nil:
    fut = rpc(jParams)
    return true

proc makeProcName(s: string): string =
  result = ""
  for c in s:
    if c.isAlphaNumeric: result.add c

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and
     params[0].kind != nnkEmpty:
    result = true

macro rpc*(server: RpcRouter, path: string, body: untyped): untyped =
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
