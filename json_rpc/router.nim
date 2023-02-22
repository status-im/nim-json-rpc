import
  std/[macros, options, strutils, tables],
  chronicles, chronos, json_serialization/writer,
  ./jsonmarshal, ./errors

export
  chronos, jsonmarshal

type
  StringOfJson* = JsonString

  # Procedure signature accepted as an RPC call by server
  RpcProc* = proc(input: JsonNode): Future[StringOfJson] {.gcsafe, raises: [Defect].}

  RpcRouter* = object
    procs*: Table[string, RpcProc]

const
  methodField = "method"
  paramsField = "params"

  JSON_PARSE_ERROR* = -32700
  INVALID_REQUEST* = -32600
  METHOD_NOT_FOUND* = -32601
  INVALID_PARAMS* = -32602
  INTERNAL_ERROR* = -32603
  SERVER_ERROR* = -32000

  defaultMaxRequestLength* = 1024 * 128

proc init*(T: type RpcRouter): T = discard

proc newRpcRouter*: RpcRouter {.deprecated.} =
  RpcRouter.init()

proc register*(router: var RpcRouter, path: string, call: RpcProc) =
  router.procs[path] = call

proc clear*(router: var RpcRouter) =
  router.procs.clear

proc hasMethod*(router: RpcRouter, methodName: string): bool = router.procs.hasKey(methodName)

func isEmpty(node: JsonNode): bool = node.isNil or node.kind == JNull

# Json reply wrappers

# https://www.jsonrpc.org/specification#response_object
proc wrapReply*(id: JsonNode, value: StringOfJson): StringOfJson =
  # Success response carries version, id and result fields only
  StringOfJson(
    """{"jsonrpc":"2.0","id":$1,"result":$2}""" % [$id, string(value)] & "\r\n")

proc wrapError*(code: int, msg: string, id: JsonNode = newJNull(),
                data: JsonNode = newJNull()): StringOfJson =
  # Error reply that carries version, id and error object only
  StringOfJson(
    """{"jsonrpc":"2.0","id":$1,"error":{"code":$2,"message":$3,"data":$4}}""" % [
      $id, $code, escapeJson(msg), $data
    ] & "\r\n")

proc route*(router: RpcRouter, node: JsonNode): Future[StringOfJson] {.async, gcsafe.} =
  if node{"jsonrpc"}.getStr() != "2.0":
    return wrapError(INVALID_REQUEST, "'jsonrpc' missing or invalid")

  let id = node{"id"}
  if id == nil:
    return wrapError(INVALID_REQUEST, "'id' missing or invalid")

  let methodName = node{"method"}.getStr()
  if methodName.len == 0:
    return wrapError(INVALID_REQUEST, "'method' missing or invalid")

  let rpcProc = router.procs.getOrDefault(methodName)
  let params = node.getOrDefault("params")

  if rpcProc == nil:
    return wrapError(METHOD_NOT_FOUND, "'" & methodName & "' is not a registered RPC method", id)
  else:
    try:
      let res = await rpcProc(if params == nil: newJArray() else: params)
      return wrapReply(id, res)
    except InvalidRequest as err:
      return wrapError(err.code, err.msg, id)
    except CatchableError as err:
      debug "Error occurred within RPC", methodName = methodName, err = err.msg
      return wrapError(
        SERVER_ERROR, methodName & " raised an exception", id, newJString(err.msg))

proc route*(router: RpcRouter, data: string): Future[string] {.async, gcsafe.} =
  ## Route to RPC from string data. Data is expected to be able to be converted to Json.
  ## Returns string of Json from RPC result/error node
  when (NimMajor, NimMinor) >= (1, 6):
    {.warning[BareExcept]:off.}

  let node =
    try: parseJson(data)
    except CatchableError as err:
      return string(wrapError(JSON_PARSE_ERROR, err.msg))
    except Exception as err:
      # TODO https://github.com/status-im/nimbus-eth2/issues/2430
      return string(wrapError(JSON_PARSE_ERROR, err.msg))

  when (NimMajor, NimMinor) >= (1, 6):
    {.warning[BareExcept]:on.}

  return string(await router.route(node))

proc tryRoute*(router: RpcRouter, data: JsonNode, fut: var Future[StringOfJson]): bool =
  ## Route to RPC, returns false if the method or params cannot be found.
  ## Expects json input and returns json output.
  let
    jPath = data.getOrDefault(methodField)
    jParams = data.getOrDefault(paramsField)
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
    rpcProcImpl = genSym(nskProc)
    rpcProcWrapper = genSym(nskProc)
  var
    setup = jsonToNim(parameters, paramsIdent)
    procBody = if body.kind == nnkStmtList: body else: body.body

  let ReturnType = if parameters.hasReturnType: parameters[0]
                   else: ident "JsonNode"

  # delegate async proc allows return and setting of result as native type
  result.add quote do:
    proc `rpcProcImpl`(`paramsIdent`: JsonNode): Future[`ReturnType`] {.async.} =
      `setup`
      `procBody`

  if ReturnType == ident"JsonNode":
    # `JsonNode` results don't need conversion
    result.add quote do:
      proc `rpcProcWrapper`(`paramsIdent`: JsonNode): Future[StringOfJson] {.async, gcsafe.} =
        return StringOfJson($(await `rpcProcImpl`(`paramsIdent`)))
  elif ReturnType == ident"StringOfJson":
    result.add quote do:
      proc `rpcProcWrapper`(`paramsIdent`: JsonNode): Future[StringOfJson] {.async, gcsafe.} =
        return await `rpcProcImpl`(`paramsIdent`)
  else:
    result.add quote do:
      proc `rpcProcWrapper`(`paramsIdent`: JsonNode): Future[StringOfJson] {.async, gcsafe.} =
        return StringOfJson($(%(await `rpcProcImpl`(`paramsIdent`))))

  result.add quote do:
    `server`.register(`path`, `rpcProcWrapper`)

  when defined(nimDumpRpcs):
    echo "\n", path, ": ", result.repr
