import json, tables, options, macros
import asyncdispatch2, router, chronicles
import jsonmarshal

export asyncdispatch2, json, jsonmarshal, router, chronicles

type
  RpcServer* = ref object of RootRef
    router*: RpcRouter

proc newRpcServer*(): RpcServer =
  new result
  result.router = newRpcRouter()

template rpc*(server: RpcServer, path: string, body: untyped): untyped =
  server.router.rpc(path, body)

template hasMethod*(server: RpcServer, methodName: string): bool = server.router.hasMethod(methodName)

# Wrapper for message processing

proc route*(server: RpcServer, line: string): Future[string] {.async, gcsafe.} =
  result = await server.router.route(line)

# Server registration

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  ## Add a name/code pair to the RPC server.
  server.router.register(name, rpc)

proc unRegisterAll*(server: RpcServer) =
  # Remove all remote procedure calls from this server.
  server.router.clear


