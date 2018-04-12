import asyncdispatch, asyncnet, json, tables, macros, strutils

type
  RpcProc* = proc (params: JsonNode): Future[JsonNode]

  RpcServer* = ref object
    socket*: AsyncSocket
    port*: Port
    address*: string
    procs*: TableRef[string, RpcProc]

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

var rpcCallRefs {.compiletime.} = newSeq[(string)]()

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  server.procs[name] = rpc

proc unRegisterAll*(server: RpcServer) = server.procs.clear

macro rpc*(prc: untyped): untyped =
  ## Converts a procedure into the following format:
  ##  <proc name>*(params: JsonNode): Future[JsonNode] {.async.}
  ## This procedure is then added into a compile-time list
  ## so that it is automatically registered for every server that
  ## calls registerRpcs(server)
  prc.expectKind nnkProcDef
  result = prc
  let
    params = prc.params
    procName = prc.name

  procName.expectKind(nnkIdent)
  
  # check there isn't already a result type
  assert params[0].kind == nnkEmpty

  # add parameter
  params.add nnkIdentDefs.newTree(
        newIdentNode("params"),
        newIdentNode("JsonNode"),
        newEmptyNode()
      )
  # set result type
  params[0] = nnkBracketExpr.newTree(
    newIdentNode("Future"),
    newIdentNode("JsonNode")
  )
  # add async pragma; we can assume there isn't an existing .async.
  # as this would mean there's a return type and fail the result check above.
  prc.addPragma(newIdentNode("async"))

  # Adds to compiletime list of rpc calls so we can register them in bulk
  # for multiple servers using `registerRpcs`.
  rpcCallRefs.add $procName

macro registerRpcs*(server: RpcServer): untyped =
  ## Step through procs currently registered with {.rpc.} and add a register call for this server
  result = newStmtList()
  result.add(quote do:
    `server`.unRegisterAll
  )
  for procName in rpcCallRefs:
    let i = ident(procName)
    result.add(quote do:
      `server`.register(`procName`, `i`)
    )

include ethprocs # TODO: This isn't ideal as it means editing code in ethprocs shows errors

proc newRpcServer*(address: string, port: Port = Port(8545)): RpcServer =
  result = RpcServer(
    socket: newAsyncSocket(),
    port: port,
    address: address,
    procs: newTable[string, RpcProc]()
  )
  result.registerRpcs
  
