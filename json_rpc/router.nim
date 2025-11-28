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

func invalidRequest(msg: string): ResponseError =
  ResponseError(code: INVALID_REQUEST, message: msg)

func methodNotFound(msg: string): ResponseError =
  ResponseError(code: METHOD_NOT_FOUND, message: msg)

func serverError(msg: string, data: JsonString): ResponseError =
  ResponseError(code: SERVER_ERROR, message: msg, data: Opt.some(data))

func applicationError(code: int, msg: string, data: Opt[JsonString]): ResponseError =
  ResponseError(code: code, message: msg, data: data)

proc respResult(req: RequestRx2, res: sink JsonString): ResponseTx =
  ResponseTx(
    kind: rkResult,
    result: res,
    id: req.id.expect("should have been checked in validateRequest"),
  )

proc respError*(req: RequestRx2, error: sink ResponseError): ResponseTx =
  ResponseTx(
    kind: rkError,
    error: error,
    id: req.id.valueOr(default(RequestId)), # `null` id on responses we can't parse
  )

proc validateRequest(router: RpcRouter, req: RequestRx2):
                       Result[RpcProc, ResponseError] =
  if req.id.isNone:
    # TODO implement notifications
    return invalidRequest("'id' missing or invalid").err

  let
    methodName = req.meth
    rpcProc = router.procs.getOrDefault(methodName)

  if rpcProc.isNil:
    return methodNotFound("'" & methodName &
      "' is not a registered RPC method").err

  ok(rpcProc)

proc wrapError(code: int, msg: string): string =
  """{"jsonrpc":"2.0","error":{"code":""" & $code &
    ""","message":""" & escapeJson(msg) & """},"id":null}"""

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
  let rpcProc = router.validateRequest(req).valueOr:
    return req.respError(error)

  try:
    debug "Processing JSON-RPC request", id = req.id, name = req.meth
    let res = await rpcProc(req.params)
    debug "Returning JSON-RPC response",
      id = req.id, name = req.meth, len = string(res).len
    req.respResult(res)
  except ApplicationError as err:
    req.respError(applicationError(err.code, err.msg, err.data))
  except CatchableError as err:
    # Note: Errors that are not specifically raised as `ApplicationError`s will
    # be returned as custom server errors.
    let methodName = req.meth
    debug "Error occurred within RPC",
      methodName = methodName, err = err.msg
    req.respError(
      serverError(
        "`" & methodName & "` raised an exception", escapeJson(err.msg).JsonString
      )
    )

proc route*(router: RpcRouter, data: string|seq[byte]):
       Future[string] {.async: (raises: []).} =
  ## Route to RPC from string data. Data is expected to be able to be
  ## converted to Json.
  ## Returns string of Json from RPC result/error node
  let request =
    try:
      JrpcSys.decode(data, RequestBatchRx)
    except IncompleteObjectError as err:
      return wrapError(INVALID_REQUEST, err.msg)
    except SerializationError as err:
      return wrapError(JSON_PARSE_ERROR, err.msg)

  case request.kind
  of rbkSingle:
    let response = await router.route(request.single)
    JrpcSys.encode(response)
  of rbkMany:
    # check raising type to ensure `value` below is safe to use
    let resFut: seq[Future[ResponseTx].Raising([])] =
      request.many.mapIt(router.route(it))

    await noCancel(allFutures(resFut))

    JrpcSys.encode(resFut.mapIt(it.value))

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
