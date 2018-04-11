import asyncdispatch, asyncnet, json, tables, strutils,
  servertypes, rpcconsts, private / [transportutils, debugutils], jsonutils, asyncutils, ethprocs,
  options

proc processMessage(server: RpcServer, client: AsyncSocket, line: string) {.async.} =
  var
    node: JsonNode
    jsonErrorState = checkJsonErrors(line, node)        # set up node and/or flag errors
  if jsonErrorState.isSome:
    let errState = jsonErrorState.get
    var id: JsonNode
    if errState.err == rjeInvalidJson: id = newJNull()  # id cannot be retrieved
    else: id = node["id"]
    await errState.err.sendJsonError(client, id, %errState.msg)
  else:
    let
      methodName = node["method"].str
      id = node["id"]

    if not server.procs.hasKey(methodName):
      await client.sendError(METHOD_NOT_FOUND, "Method not found", id, %(methodName & " is not a registered method."))
    else:
      let callRes = server.procs[methodName](node["params"])
      await client.send($wrapReply(id, callRes, newJNull()) & "\c\l")

proc processClient(server: RpcServer, client: AsyncSocket) {.async.} =
  while true:
    let line = await client.recvLine()
    if line == "":
      # Disconnected.
      client.close()
      break

    ifDebug: echo "Process client: ", server.port, ":" & line

    let fut = processMessage(server, client, line)
    await fut
    if fut.failed:
      if fut.readError of RpcProcError:
        # TODO: Currently exceptions in rpc calls are not properly handled
        let err = fut.readError.RpcProcError
        await client.sendError(err.code, err.msg, err.data)
      else:
        await client.sendError(-32000, "Error", %getCurrentExceptionMsg())

proc serve*(server: RpcServer) {.async.} =
  server.registerEthereumRpcs
  server.socket.bindAddr(server.port, server.address)
  server.socket.listen()

  while true:
    let client = await server.socket.accept()
    asyncCheck server.processClient(client)

