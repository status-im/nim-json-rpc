import
  json, tables, asyncdispatch2, jsonmarshal, strutils, macros,  
  chronicles, options
export asyncdispatch2, json, jsonmarshal

type
  RpcJsonError* = enum rjeInvalidJson, rjeVersionError, rjeNoMethod, rjeNoId, rjeNoParams
  RpcJsonErrorContainer* = tuple[err: RpcJsonError, msg: string]

  # Procedure signature accepted as an RPC call by server
  RpcProc* = proc(input: JsonNode): Future[JsonNode] {.gcsafe.}
  
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
  resultField = "result"
  errorField = "error"
  codeField = "code"
  messageField = "message"
  dataField = "data"
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
      (INVALID_PARAMS, "No parameters specified")
    ]

proc newRpcRouter*: RpcRouter =
  result.procs = newTable[string, RpcProc]()

proc register*(router: var RpcRouter, path: string, call: RpcProc) =
  router.procs.add(path, call)

proc clear*(router: var RpcRouter) = router.procs.clear

proc hasMethod*(router: RpcRouter, methodName: string): bool = router.procs.hasKey(methodName)

template isEmpty(node: JsonNode): bool = node.isNil or node.kind == JNull

# Json state checking

template jsonValid*(jsonString: string, node: var JsonNode): (bool, string) =
  var
    valid = true
    msg = ""
  try: node = parseJson(line)
  except:
    valid = false
    msg = getCurrentExceptionMsg()
    debug "Cannot process json", json = jsonString, msg = msg
  (valid, msg)

proc checkJsonState*(line: string,
                      node: var JsonNode): Option[RpcJsonErrorContainer] =
  ## Tries parsing line into node, if successful checks required fields
  ## Returns: error state or none
  let res = jsonValid(line, node)
  if not res[0]:
    return some((rjeInvalidJson, res[1]))
  if not node.hasKey(idField):
    return some((rjeNoId, ""))
  let jVer = node{jsonRpcField}
  if jVer != nil and jVer.kind != JNull and jVer != %"2.0":
    return some((rjeVersionError, ""))
  if not node.hasKey(methodField):
    return some((rjeNoMethod, ""))
  if not node.hasKey(paramsField):
    return some((rjeNoParams, ""))
  return none(RpcJsonErrorContainer)

# Json reply wrappers

proc wrapReply*(id: JsonNode, value: JsonNode, error: JsonNode): JsonNode =
  return %{jsonRpcField: %"2.0", idField: id, resultField: value, errorField: error}

proc wrapError*(code: int, msg: string, id: JsonNode,
                data: JsonNode = newJNull()): JsonNode =
  # Create standardised error json
  result = %{codeField: %(code), idField: id, messageField: %msg, dataField: data}
  debug "Error generated", error = result, id = id

proc route*(router: RpcRouter, node: JsonNode): Future[JsonNode] {.async, gcsafe.} =
  ## Assumes correct setup of node
  let
    methodName = node[methodField].str
    id = node[idField]
    rpcProc = router.procs.getOrDefault(methodName)

  if rpcProc.isNil:
    let
      methodNotFound = %(methodName & " is not a registered RPC method.")
      error = wrapError(METHOD_NOT_FOUND, "Method not found", id, methodNotFound)
    result = wrapReply(id, newJNull(), error)
  else:
    let
      jParams = node[paramsField]
      res = await rpcProc(jParams)
      errCode = res.getOrDefault(codeField)
      errMsg = res.getOrDefault(messageField)
    if errCode != nil and errCode.kind == JInt and
      errMsg != nil and errMsg.kind == JString:
      let error = wrapError(errCode.getInt, methodName & " raised an exception", id, errMsg)
      result = wrapReply(id, newJNull(), error)
    else:
      result = wrapReply(id, res, newJNull())

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
      if errState.err == rjeInvalidJson or errState.err == rjeNoId:
        newJNull()
      else:
        node["id"]
    let
      # fixed error code and message
      errKind = jsonErrorMessages[errState.err]
      # pass on the actual error message
      fullMsg = errKind[1] & " " & errState[1] 
      res = wrapError(code = errKind[0], msg = fullMsg, id = id)
    # return error state as json
    result = $res & messageTerminator
  else:
    let res = await router.route(node)
    result = $res & messageTerminator

proc tryRoute*(router: RpcRouter, data: JsonNode, fut: var Future[JsonNode]): bool =
  ## Route to RPC, returns false if the method or params cannot be found.
  ## Expects json input and returns json output.
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
        let msg = getCurrentExceptionMsg()
        debug "Error occurred within RPC ", path = `path`, errorMessage = msg
        `res` = %*{codeField: SERVER_ERROR, messageField: %msg}
        
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
