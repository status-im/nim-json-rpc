# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/tables,
  chronos,
  ./router,
  ./jsonmarshal

export chronos, jsonmarshal, router

type
  RpcServer* = ref object of RootRef
    router*: RpcRouter

proc new(T: type RpcServer): T =
  T(router: RpcRouter.init())

proc newRpcServer*(): RpcServer {.deprecated.} = RpcServer.new()

template rpc*(server: RpcServer, path: string, body: untyped): untyped =
  server.router.rpc(path, body)

template hasMethod*(server: RpcServer, methodName: string): bool =
  server.router.hasMethod(methodName)

proc executeMethod*(server: RpcServer,
                    methodName: string,
                    args: JsonNode): Future[StringOfJson] =
  server.router.procs[methodName](args)

# Wrapper for message processing

proc route*(server: RpcServer, line: string): Future[string] {.gcsafe.} =
  server.router.route(line)

# Server registration

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  ## Add a name/code pair to the RPC server.
  server.router.register(name, rpc)

proc unRegisterAll*(server: RpcServer) =
  # Remove all remote procedure calls from this server.
  server.router.clear
