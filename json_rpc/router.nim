# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[macros, sequtils, tables, json],
  stew/byteutils,
  chronicles,
  chronos,
  ./private/[jrpc_sys, server_handler_wrapper],
  ./[errors, jsonmarshal]

export chronos, jsonmarshal, json, jrpc_sys

logScope:
  topics = "jsonrpc router"

type
  RpcProc* = proc(params: RequestParamsRx): Future[JsonString] {.async.}
    ## Procedure signature accepted as an RPC call by server - if the function
    ## has no return value, return `JsonString("null")`

  RpcRouter* = object
    procs*: Table[string, RpcProc]

const
  # https://www.jsonrpc.org/specification#error_object
  JSON_PARSE_ERROR* = -32700
  INVALID_REQUEST* = -32600
  METHOD_NOT_FOUND* = -32601
  INVALID_PARAMS* = -32602
  INTERNAL_ERROR* = -32603
  SERVER_ERROR* = -32000
  JSON_ENCODE_ERROR* = -32001

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func respResult(req: RequestRx2, res: sink JsonString): ResponseTx =
  if req.id.isSome():
    ResponseTx(kind: rkResult, result: res, id: req.id.expect("just checked"))
  else:
    default(ResponseTx)

func respError(
    req: RequestRx2,
    code: int,
    msg: sink string,
    data: sink Opt[JsonString] = Opt.none(JsonString),
): ResponseTx =
  if req.id.isSome():
    ResponseTx(
      kind: rkError,
      error: ResponseError(code: code, message: msg, data: data),
      id: req.id.expect("just checked"),
    )
  else:
    default(ResponseTx)

func methodNotFound(req: RequestRx2): ResponseTx =
  req.respError(METHOD_NOT_FOUND, "'" & req.meth & "' is not a registered RPC method")

func serverError(req: RequestRx2, data: sink JsonString): ResponseTx =
  req.respError(SERVER_ERROR, "`" & req.meth & "` raised an exception", Opt.some(data))

func lookup(router: RpcRouter, req: RequestRx2): Opt[RpcProc] =
  let rpcProc = router.procs.getOrDefault(req.meth)

  if rpcProc.isNil:
    Opt.none(RpcProc)
  else:
    ok(rpcProc)

func wrapError*(code: int, msg: string): seq[byte] =
  JrpcSys.withWriter(writer):
    writer.writeValue(
      ResponseTx(kind: rkError, error: ResponseError(code: code, message: msg))
    )

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(T: type RpcRouter): T = discard

proc register*(router: var RpcRouter, path: string, call: RpcProc) =
  router.procs[path] = call

proc clear*(router: var RpcRouter) =
  router.procs.clear

proc hasMethod*(router: RpcRouter, methodName: string): bool =
  router.procs.hasKey(methodName)

proc route*(router: RpcRouter, req: RequestRx2):
             Future[ResponseTx] {.async: (raises: []).} =
  let rpcProc = router.lookup(req).valueOr:
    debug "Request for non-registered method", id = req.id, methodName = req.meth
    return req.methodNotFound()

  try:
    debug "Processing JSON-RPC request", id = req.id, methodName = req.meth
    let res = await rpcProc(req.params)
    debug "Processed JSON-RPC request", id = req.id, methodName = req.meth, len = string(res).len
    req.respResult(res)
  except ApplicationError as err:
    debug "Error occurred within RPC", methodName = req.meth, err = err.msg, code = err.code
    req.respError(err.code, err.msg, err.data)
  except CatchableError as err:
    debug "Error occurred within RPC", methodName = req.meth, err = err.msg

    # Errors that are not specifically raised as `ApplicationError`s will be
    # returned as custom server errors.
    req.serverError(escapeJson(err.msg).JsonString)

proc route*(
    router: RpcRouter, request: RequestBatchRx
): Future[seq[byte]] {.async: (raises: []).} =
  ## Routes the request(s) requests and encodes the responses encoded as JSON

  case request.kind
  of rbkSingle:
    let response = await router.route(request.single)
    if request.single.id.isSome:
      JrpcSys.withWriter(writer):
        writer.writeValue(response)
    else:
      default(seq[byte])
  of rbkMany:
    # check raising type to ensure `value` below is safe to use
    var responses: seq[Future[ResponseTx].Raising([])] =
      request.many.mapIt(router.route(it))

    await noCancel(allFutures(responses))

    # If all requests are notifications, we should not make a response
    if request.many.anyIt(it.id.isSome()):
      JrpcSys.withWriter(writer):
        writer.writeArray:
          for i, fut in responses.mpairs():
            if request.many[i].id.isSome():
              writer.writeValue(responses[i].value())
            reset(fut) # Release memory eagerly in case response is big
    else:
      default(seq[byte])

proc route*(
    router: RpcRouter, data: string | seq[byte]
): Future[string] {.async: (raises: []).} =
  ## Route to RPC from string data.
  ##
  ## `data` must be a valid JSON-RPC request or batch request.
  ##
  ## Returns the JSON-encoded response.
  let request =
    try:
      JrpcSys.decode(data, RequestBatchRx)
    except IncompleteObjectError as err:
      return string.fromBytes(wrapError(INVALID_REQUEST, err.msg))
    except SerializationError as err:
      return string.fromBytes(wrapError(JSON_PARSE_ERROR, err.msg))

  string.fromBytes(await router.route(request))

macro rpc(
    Format: type SerializationFormat, server: RpcRouter, path: static[string], body: untyped
): untyped =
  ## Define a remote procedure call.
  ## Input and return parameters are defined using the ``do`` notation.
  ## For example:
  ## .. code-block:: nim
  ##    myServer.rpc("path") do(param1: int, param2: float) -> string:
  ##      result = $param1 & " " & $param2
  ##    ```
  ## Input parameters are automatically marshalled from json to Nim types,
  ## and output parameters are automatically marshalled to json for transport.
  let
    params = body.findChild(it.kind == nnkFormalParams)
    procBody = if body.kind == nnkStmtList: body else: body.body
    procWrapper = genSym(nskProc, $path & "_rpcWrapper")

  result = wrapServerHandler($path, params, procBody, procWrapper, Format)

  result.add quote do:
    `server`.register(`path`, `procWrapper`)

  when defined(nimDumpRpcs):
    echo "\n", path, ": ", result.repr

template rpc*(server: RpcRouter, path: string, Format, body: untyped): untyped =
  rpc(Format, server, path, body)

template rpc*(server: RpcRouter, path: string, body: untyped): untyped =
  rpc(JrpcConv, server, path, body)

{.pop.}
