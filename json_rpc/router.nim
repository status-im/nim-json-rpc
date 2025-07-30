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
  std/[macros, tables, json],
  chronicles,
  chronos,
  ./private/server_handler_wrapper,
  ./errors,
  ./private/jrpc_sys,
  ./jsonmarshal

export
  chronos,
  jsonmarshal,
  json

logScope:
  topics = "json-rpc-router"

type
  # Procedure signature accepted as an RPC call by server
  RpcProc* = proc(params: RequestParamsRx): Future[JsonString]
              {.async.}

  RpcRouter* = object
    procs*: Table[string, RpcProc]

const
  JSON_PARSE_ERROR* = -32700
  INVALID_REQUEST* = -32600
  METHOD_NOT_FOUND* = -32601
  INVALID_PARAMS* = -32602
  INTERNAL_ERROR* = -32603
  SERVER_ERROR* = -32000
  JSON_ENCODE_ERROR* = -32001

  defaultMaxRequestLength* = 1024 * 128

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func invalidRequest(msg: string): ResponseError =
  ResponseError(code: INVALID_REQUEST, message: msg)

func methodNotFound(msg: string): ResponseError =
  ResponseError(code: METHOD_NOT_FOUND, message: msg)

func serverError(msg: string, data: JsonString): ResponseError =
  ResponseError(code: SERVER_ERROR, message: msg, data: Opt.some(data))

func somethingError(code: int, msg: string): ResponseError =
  ResponseError(code: code, message: msg)

func applicationError(code: int, msg: string, data: Opt[JsonString]): ResponseError =
  ResponseError(code: code, message: msg, data: data)

proc validateRequest(router: RpcRouter, req: RequestRx):
                       Result[RpcProc, ResponseError] =
  if req.jsonrpc.isNone:
    return invalidRequest("'jsonrpc' missing or invalid").err

  if req.id.kind == riNull:
    return invalidRequest("'id' missing or invalid").err

  if req.meth.isNone:
    return invalidRequest("'method' missing or invalid").err

  let
    methodName = req.meth.get
    rpcProc = router.procs.getOrDefault(methodName)

  if rpcProc.isNil:
    return methodNotFound("'" & methodName &
      "' is not a registered RPC method").err

  ok(rpcProc)

proc wrapError(err: ResponseError, id: RequestId): ResponseTx =
  ResponseTx(
    id: id,
    kind: rkError,
    error: err,
  )

proc wrapError(code: int, msg: string, id: RequestId): ResponseTx =
  ResponseTx(
    id: id,
    kind: rkError,
    error: somethingError(code, msg),
  )

proc wrapReply(res: JsonString, id: RequestId): ResponseTx =
  ResponseTx(
    id: id,
    kind: rkResult,
    result: res,
  )

proc wrapError(code: int, msg: string): string =
  """{"jsonrpc":"2.0","id":null,"error":{"code":""" & $code &
    ""","message":""" & escapeJson(msg) & "}}"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(T: type RpcRouter): T = discard

proc register*(router: var RpcRouter, path: string, call: RpcProc) =
  # this proc should not raise exception
  try:
    router.procs[path] = call
  except CatchableError as exc:
    doAssert(false, exc.msg)

proc clear*(router: var RpcRouter) =
  router.procs.clear

proc hasMethod*(router: RpcRouter, methodName: string): bool =
  router.procs.hasKey(methodName)

proc route*(router: RpcRouter, req: RequestRx):
             Future[ResponseTx] {.async: (raises: []).} =
  let rpcProc = router.validateRequest(req).valueOr:
    return wrapError(error, req.id)

  try:
    debug "Processing JSON-RPC request", id = req.id, name = req.`method`.get()
    let res = await rpcProc(req.params)
    debug "Returning JSON-RPC response",
      id = req.id, name = req.`method`.get(), len = string(res).len
    return wrapReply(res, req.id)
  except ApplicationError as err:
    return wrapError(applicationError(err.code, err.msg, err.data), req.id)
  except InvalidRequest as err:
    # TODO: deprecate / remove this usage and use InvalidRequest only for
    # internal errors.
    return wrapError(err.code, err.msg, req.id)
  except CatchableError as err:
    # Note: Errors that are not specifically raised as `ApplicationError`s will
    # be returned as custom server errors.
    let methodName = req.meth.get # this Opt already validated
    debug "Error occurred within RPC",
      methodName = methodName, err = err.msg
    return serverError("`" & methodName & "` raised an exception",
      escapeJson(err.msg).JsonString).
      wrapError(req.id)

proc route*(router: RpcRouter, data: string|seq[byte]):
       Future[string] {.async: (raises: []).} =
  ## Route to RPC from string data. Data is expected to be able to be
  ## converted to Json.
  ## Returns string of Json from RPC result/error node
  let request =
    try:
      JrpcSys.decode(data, RequestBatchRx)
    except CatchableError as err:
      return wrapError(JSON_PARSE_ERROR, err.msg)

  try:
    if request.kind == rbkSingle:
      let response = await router.route(request.single)
      JrpcSys.encode(response)
    elif request.many.len == 0:
      wrapError(INVALID_REQUEST, "no request object in request array")
    else:
      var resFut: seq[Future[ResponseTx]]
      for req in request.many:
        resFut.add router.route(req)
      await noCancel(allFutures(resFut))
      var response = ResponseBatchTx(kind: rbkMany)
      for fut in resFut:
        response.many.add fut.read()
      JrpcSys.encode(response)
  except CatchableError as err:
    wrapError(JSON_ENCODE_ERROR, err.msg)

macro rpc*(server: RpcRouter, path: static[string], body: untyped): untyped =
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

  result = wrapServerHandler($path, params, procBody, procWrapper)

  result.add quote do:
    `server`.register(`path`, `procWrapper`)

  when defined(nimDumpRpcs):
    echo "\n", path, ": ", result.repr

{.pop.}
