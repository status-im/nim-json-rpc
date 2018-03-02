import asyncdispatch, asyncnet, json, tables

type
  RpcProc* = proc (params: JsonNode): JsonNode

  RpcServer* = ref object
    socket*: AsyncSocket
    port*: Port
    address*: string
    procs*: TableRef[string, RpcProc]

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

proc newRpcServer*(address: string, port: Port = Port(8545)): RpcServer =
  RpcServer(
    socket: newAsyncSocket(),
    port: port,
    address: address,
    procs: newTable[string, RpcProc]()
  )

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  server.procs[name] = rpc