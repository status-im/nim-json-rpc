import json, tables, options, macros, chronicles
import asyncdispatch2, router
import jsonmarshal

export asyncdispatch2, json, jsonmarshal, router

logScope:
  topics = "RpcServer"

type
  RpcJsonError* = enum rjeInvalidJson, rjeVersionError, rjeNoMethod, rjeNoId, rjeNoParams

  RpcJsonErrorContainer* = tuple[err: RpcJsonError, msg: string]

  RpcServer*[S] = ref object
    servers*: seq[S]
    router*: RpcRouter

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

  RpcBindError* = object of Exception
  RpcAddressUnresolvableError* = object of Exception

const
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

proc newRpcServer*[S](): RpcServer[S] =
  new result
  result.router = newRpcRouter()
  result.servers = @[]

# Utility functions
# TODO: Move outside server?
#func `%`*(p: Port): JsonNode = %(p.int)

template rpc*(server: RpcServer, path: string, body: untyped): untyped =
  server.router.rpc(path, body)

template hasMethod*(server: RpcServer, methodName: string): bool = server.router.hasMethod(methodName)

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
  if not node.hasKey("id"):
    return some((rjeNoId, ""))
  let jVer = node{"jsonrpc"}
  if jVer != nil and jVer.kind != JNull and jVer != %"2.0":
    return some((rjeVersionError, ""))
  if not node.hasKey("method"):
    return some((rjeNoMethod, ""))
  if not node.hasKey("params"):
    return some((rjeNoParams, ""))
  return none(RpcJsonErrorContainer)

# Json reply wrappers

proc wrapReply*(id: JsonNode, value: JsonNode, error: JsonNode): string =
  let node = %{"jsonrpc": %"2.0", "result": value, "error": error, "id": id}
  return $node & "\c\l"

proc wrapError*(code: int, msg: string, id: JsonNode,
                data: JsonNode = newJNull()): JsonNode =
  # Create standardised error json
  result = %{"code": %(code), "id": id, "message": %msg, "data": data}
  debug "Error generated", error = result, id = id

# Server message processing

proc processMessages*[T](server: RpcServer[T], line: string): Future[string] {.async, gcsafe.} =
  var
    node: JsonNode
    # parse json node and/or flag missing fields and errors
    jsonErrorState = checkJsonState(line, node)

  if jsonErrorState.isSome:
    let errState = jsonErrorState.get
    var id =
      if errState.err == rjeInvalidJson or errState.err == rjeNoId:
        newJNull()
      else:
        node["id"]
    let errMsg = jsonErrorMessages[errState.err]
    # return error state as json
    result = $wrapError(
      code = errMsg[0],
      msg = errMsg[1],
      id = id)
  else:
    let
      methodName = node["method"].str
      id = node["id"]
    var callRes: Future[JsonNode]

    if server.router.ifRoute(node, callRes):
      let res = await callRes
      result = $wrapReply(id, res, newJNull())
    else:
      let
        methodNotFound = %(methodName & " is not a registered method.")
        error = wrapError(METHOD_NOT_FOUND, "Method not found", id, methodNotFound)
      result = $wrapReply(id, newJNull(), error)

proc start*(server: RpcServer) =
  ## Start the RPC server.
  for item in server.servers:
    item.start()

proc stop*(server: RpcServer) =
  ## Stop the RPC server.
  for item in server.servers:
    item.stop()

proc close*(server: RpcServer) =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    item.close()

# Server registration

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  ## Add a name/code pair to the RPC server.
  server.router.addRoute(name, rpc)

proc unRegisterAll*(server: RpcServer) =
  # Remove all remote procedure calls from this server.
  server.router.clear


