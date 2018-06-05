import asyncdispatch, asyncnet, json, tables, strutils,
  servertypes, rpcconsts, private / debugutils, jsonutils, asyncutils,
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
      let callRes = await server.procs[methodName](node["params"])
      await client.send(wrapReply(id, callRes, newJNull()))

proc processClient(server: RpcServer, client: AsyncSocket) {.async.} =
  while true:
    let line = await client.recvLine()
    if line == "":
      # Disconnected.
      client.close()
      break

    ifDebug: echo "Process client: ", server.port, ":" & line

    let future = processMessage(server, client, line)
    await future
    if future.failed:
      if future.readError of RpcProcError:
        let err = future.readError.RpcProcError
        await client.sendError(err.code, err.msg, err.data)
      elif future.readError of ValueError:
        let err = future.readError[].ValueError
        await client.sendError(INVALID_PARAMS, err.msg, %"")
      else:
        await client.sendError(SERVER_ERROR, "Error: Unknown error occurred", %"")

proc serve*(server: RpcServer) {.async.} =
  server.socket.bindAddr(server.port, server.address)
  server.socket.listen()

  while true:
    let client = await server.socket.accept()
    asyncCheck server.processClient(client)


