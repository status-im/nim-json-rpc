import json
import chronicles, chronos
import ../server

const newsUseChronos = true
include news

type
  WebsocketServer* = ref object of RpcServer

proc processClient(server: StreamServer, socket: WebSocket) {.async, gcsafe.} =
  ## Process transport data to the RPC server
  var rpc = getUserData[WebsocketServer](server)
  while true:
    var value = await socket.receiveString()

    debug "Processing message", address = socket.remoteAddress(), line = value

    let res = await rpc.route(value)
    result = socket.send(res)
