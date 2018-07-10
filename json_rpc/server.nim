import json, tables, options, macros
import asyncdispatch2, router
import jsonmarshal

export asyncdispatch2, json, jsonmarshal, router

type
  RpcServer*[S] = ref object
    servers*: seq[S]
    router*: RpcRouter

proc newRpcServer*[S](): RpcServer[S] =
  new result
  result.router = newRpcRouter()
  result.servers = @[]

template rpc*(server: RpcServer, path: string, body: untyped): untyped =
  server.router.rpc(path, body)

template hasMethod*(server: RpcServer, methodName: string): bool = server.router.hasMethod(methodName)

# Wrapper for message processing

proc route*[T](server: RpcServer[T], line: string): Future[string] {.async, gcsafe.} =
  result = await server.router.route(line)

# Server registration

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  ## Add a name/code pair to the RPC server.
  server.router.addRoute(name, rpc)

proc unRegisterAll*(server: RpcServer) =
  # Remove all remote procedure calls from this server.
  server.router.clear


