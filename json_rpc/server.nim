# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[json, sequtils, sets],
  chronos,
  ./[client, errors, jsonmarshal, router],
  ./private/jrpc_sys,
  ./private/shared_wrapper

export chronos, client, jsonmarshal, router, sets

type
  RpcServer* = ref object of RootRef
    router*: RpcRouter

    # For servers that expose bidirectional connections, keep track of them
    connections*: HashSet[RpcConnection]

# ------------------------------------------------------------------------------
# Constructors
# ------------------------------------------------------------------------------

proc new*(T: type RpcServer): T =
  T(router: RpcRouter.init())

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template rpc*(server: RpcServer, path: string, flavorType, body: untyped): untyped =
  server.router.rpc(path, flavorType, body)

template rpc*(server: RpcServer, path: string, body: untyped): untyped =
  server.router.rpc(path, body)

template hasMethod*(server: RpcServer, methodName: string): bool =
  server.router.hasMethod(methodName)

proc executeMethod*(server: RpcServer,
                    methodName: string,
                    params: RequestParamsTx): Future[JsonString] {.async: (raises: [CancelledError, JsonRpcError]).} =

  let
    req = requestTx(methodName, params, 0)
    reqData = JrpcSys.encode(req)
    respData = await server.router.route(reqData)

  processsSingleResponse(respData.toOpenArrayByte(0, respData.high()), 0)

proc executeMethod*(
    server: RpcServer, methodName: string, args: JsonNode, Flavor: type SerializationFormat
): Future[JsonString] {.async: (raises: [CancelledError, JsonRpcError], raw: true).} =
  let params = paramsTx(args, Flavor)
  server.executeMethod(methodName, params)

proc executeMethod*(
    server: RpcServer, methodName: string, args: JsonNode
): Future[JsonString] {.async: (raises: [CancelledError, JsonRpcError], raw: true).} =
  let params = paramsTx(args, JrpcConv)
  server.executeMethod(methodName, params)

proc executeMethod*(server: RpcServer,
                    methodName: string,
                    args: JsonString): Future[JsonString] {.async: (raises: [CancelledError, JsonRpcError]).} =

  let params = try:
    let x = JrpcSys.decode(args.string, RequestParamsRx)
    x.toTx
  except SerializationError as exc:
    raise newException(JsonRpcError, exc.msg)

  await server.executeMethod(methodName, params)

# Wrapper for message processing

proc route*(server: RpcServer, line: string): Future[string] {.async: (raises: [], raw: true).} =
  server.router.route(line)
proc route*(server: RpcServer, line: seq[byte]): Future[string] {.async: (raises: [], raw: true).} =
  server.router.route(line)

proc notify*(
    server: RpcServer, name: string, params: RequestParamsTx
) {.async: (raises: [CancelledError]).} =
  let notifications = server.connections.mapIt(it.notify(name, params))
  # Discard results, we don't care here ..
  await allFutures(notifications)

# Server registration

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  ## Add a name/code pair to the RPC server.
  server.router.register(name, rpc)

proc unRegisterAll*(server: RpcServer) =
  # Remove all remote procedure calls from this server.
  server.router.clear

{.pop.}
