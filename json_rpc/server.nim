# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/json,
  chronos,
  ./router,
  ./jsonmarshal,
  ./private/jrpc_sys,
  ./private/shared_wrapper,
  ./private/errors

export
  chronos,
  jsonmarshal,
  router

type
  RpcServer* = ref object of RootRef
    router*: RpcRouter

{.push gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Constructors
# ------------------------------------------------------------------------------

proc new*(T: type RpcServer): T =
  T(router: RpcRouter.init())

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template rpc*(server: RpcServer, path: string, body: untyped): untyped =
  server.router.rpc(path, body)

template hasMethod*(server: RpcServer, methodName: string): bool =
  server.router.hasMethod(methodName)

proc executeMethod*(server: RpcServer,
                    methodName: string,
                    params: RequestParamsTx): Future[JsonString]
                      {.gcsafe, raises: [JsonRpcError].} =

  let
    req = requestTx(methodName, params, RequestId(kind: riNumber, num: 0))
    reqData = JrpcSys.encode(req).JsonString

  server.router.tryRoute(reqData, result).isOkOr:
    raise newException(JsonRpcError, error)

proc executeMethod*(server: RpcServer,
                    methodName: string,
                    args: JsonNode): Future[JsonString]
                      {.gcsafe, raises: [JsonRpcError].} =

  let params = paramsTx(args)
  server.executeMethod(methodName, params)

# Wrapper for message processing

proc route*(server: RpcServer, line: string): Future[string] {.gcsafe.} =
  server.router.route(line)

# Server registration

proc register*(server: RpcServer, name: string, rpc: RpcProc) {.gcsafe, raises: [CatchableError].} =
  ## Add a name/code pair to the RPC server.
  server.router.register(name, rpc)

proc unRegisterAll*(server: RpcServer) =
  # Remove all remote procedure calls from this server.
  server.router.clear

{.pop.}
