import
  json, tables, strutils, macros, options,
  chronicles, chronos, json_serialization/writer,
  jsonmarshal

export
  chronos, json, jsonmarshal

type
  RpcJsonError* = enum
    rjeInvalidJson, rjeVersionError, rjeNoMethod, rjeNoId, rjeNoParams, rjeNoJObject
  RpcJsonErrorContainer* = tuple[err: RpcJsonError, msg: string]

  StringOfJson* = JsonString

  # Procedure signature accepted as an RPC call by server
  RpcProc* = proc(input: JsonNode): Future[StringOfJson] {.gcsafe.}

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

  RpcBindError* = object of Exception
  RpcAddressUnresolvableError* = object of Exception

  RpcRouter* = object
    procs*: TableRef[string, RpcProc]

const
  methodField = "method"
  paramsField = "params"
  jsonRpcField = "jsonrpc"
  idField = "id"
  messageTerminator = "\c\l"

  JSON_PARSE_ERROR* = -32700
  INVALID_REQUEST* = -32600
  METHOD_NOT_FOUND* = -32601
  INVALID_PARAMS* = -32602
  INTERNAL_ERROR* = -32603
  SERVER_ERROR* = -32000

  defaultMaxRequestLength* = 1024 * 128
  jsonErrorMessages*: array[RpcJsonError, (int, string)] =
    [
      (JSON_PARSE_ERROR, "Invalid JSON"),
      (INVALID_REQUEST, "JSON 2.0 required"),
      (INVALID_REQUEST, "No method requested"),
      (INVALID_REQUEST, "No id specified"),
      (INVALID_PARAMS, "No parameters specified"),
      (INVALID_PARAMS, "Invalid request object")
    ]

proc newRpcRouter*: RpcRouter =
  result.procs = newTable[string, RpcProc]()

proc register*(router: var RpcRouter, path: string, call: RpcProc) =
  router.procs.add(path, call)

proc clear*(router: var RpcRouter) = router.procs.clear

proc hasMethod*(router: RpcRouter, methodName: string): bool = router.procs.hasKey(methodName)

func isEmpty(node: JsonNode): bool = node.isNil or node.kind == JNull

# Json state checking

template jsonValid*(jsonString: string, node: var JsonNode): (bool, string) =
  var
    valid = true
    msg = ""
  try:
    node = parseJson(line)
    # Handle cases where params is omitted
    if not node.hasKey(paramsField):
        node.add(paramsField, newJArray())
  except CatchableError as exc:
    valid = false
    msg = exc.msg
    debug "Cannot process json", json = jsonString, msg = msg
  (valid, msg)

proc checkJsonState*(line: string,
                      node: var JsonNode): Option[RpcJsonErrorContainer] =
  ## Tries parsing line into node, if successful checks required fields
  ## Returns: error state or none
  let res = jsonValid(line, node)
  if not res[0]:
    return some((rjeInvalidJson, res[1]))
  if node.kind != JObject:
    return some((rjeNoJObject, ""))
  if not node.hasKey(idField):
    return some((rjeNoId, ""))
  let jVer = node{jsonRpcField}
  if jVer != nil and jVer.kind != JNull and jVer != %"2.0":
    return some((rjeVersionError, ""))
  if not node.hasKey(methodField) or node[methodField].kind != JString:
    return some((rjeNoMethod, ""))
  if not node.hasKey(paramsField):
    return some((rjeNoParams, ""))
  return none(RpcJsonErrorContainer)

# Json reply wrappers

proc wrapReply*(id: JsonNode, value, error: StringOfJson): StringOfJson =
  return StringOfJson(
    """{"jsonrpc":"2.0","id":$1,"result":$2,"error":$3}""" % [
      $id, string(value), string(error)
    ])

proc wrapError*(code: int, msg: string, id: JsonNode,
                data: JsonNode = newJNull()): StringOfJson {.gcsafe.} =
  # Create standardised error json
  result = StringOfJson(
    """{"code":$1,"id":$2,"message":$3,"data":$4}""" % [
      $code, $id, escapeJson(msg), $data
    ])
  debug "Error generated", error = result, id = id

proc route*(router: RpcRouter, node: JsonNode): Future[StringOfJson] {.async, gcsafe.} =
  ## Assumes correct setup of node
  let
    methodName = node[methodField].str
    id = node[idField]
    rpcProc = router.procs.getOrDefault(methodName)

  if rpcProc.isNil:
    let
      methodNotFound = %(methodName & " is not a registered RPC method.")
      error = wrapError(METHOD_NOT_FOUND, "Method not found", id, methodNotFound)
    result = wrapReply(id, StringOfJson("null"), error)
  else:
    try:
      let jParams = node[paramsField]
      let res = await rpcProc(jParams)
      result = wrapReply(id, res, StringOfJson("null"))
    except CatchableError as err:
      debug "Error occurred within RPC", methodName, errorMessage = err.msg
      let error = wrapError(SERVER_ERROR, methodName & " raised an exception",
                            id, newJString(err.msg))
      result = wrapReply(id, StringOfJson("null"), error)

proc route*(router: RpcRouter, data: string): Future[string] {.async, gcsafe.} =
  ## Route to RPC from string data. Data is expected to be able to be converted to Json.
  ## Returns string of Json from RPC result/error node
  var
    node: JsonNode
    # parse json node and/or flag missing fields and errors
    jsonErrorState = checkJsonState(data, node)

  if jsonErrorState.isSome:
    let errState = jsonErrorState.get
    var id =
      if errState.err == rjeInvalidJson or
         errState.err == rjeNoId or
         errState.err == rjeNoJObject:
        newJNull()
      else:
        node["id"]
    let
      # const error code and message
      errKind = jsonErrorMessages[errState.err]
      # pass on the actual error message
      fullMsg = errKind[1] & " " & errState[1]
      res = wrapError(code = errKind[0], msg = fullMsg, id = id)
    # return error state as json
    result = string(res) & messageTerminator
  else:
    let res = await router.route(node)
    result = string(res) & messageTerminator

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
    errJson = newIdentNode("errJson")
  var
    setup = jsonToNim(parameters, paramsIdent)
    procBody = if body.kind == nnkStmtList: body else: body.body

  let ReturnType = if parameters.hasReturnType: parameters[0]
                   else: ident "JsonNode"

  # delegate async proc allows return and setting of result as native type
  result.add quote do:
    proc `doMain`(`paramsIdent`: JsonNode): Future[`ReturnType`] {.async.} =
      `setup`
      `procBody`

  if ReturnType == ident"JsonNode":
    # `JsonNode` results don't need conversion
    result.add quote do:
      proc `procName`(`paramsIdent`: JsonNode): Future[StringOfJson] {.async, gcsafe.} =
        return StringOfJson($(await `doMain`(`paramsIdent`)))
  elif ReturnType == ident"StringOfJson":
    result.add quote do:
      proc `procName`(`paramsIdent`: JsonNode): Future[StringOfJson] {.async, gcsafe.} =
        return await `doMain`(`paramsIdent`)
  else:
    result.add quote do:
      proc `procName`(`paramsIdent`: JsonNode): Future[StringOfJson] {.async, gcsafe.} =
        return StringOfJson($(%(await `doMain`(`paramsIdent`))))

  result.add quote do:
    `server`.register(`path`, `procName`)

  when defined(nimDumpRpcs):
    echo "\n", pathStr, ": ", result.repr
