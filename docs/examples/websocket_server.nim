# ANCHOR: All
# websocket_server.nim

{.push gcsafe, raises: [].}

import json_rpc/rpcserver
import ./rpc_format

export rpcserver

proc setupServer(srv: RpcServer) =
  srv.rpc(RpcConv):
    proc hello(input: string): string =
      "Hello " & input

proc startServer*(): RpcWebSocketServer {.raises: [JsonRpcError].} =
  # ANCHOR: ServerConnect
  let srv = newRpcWebSocketServer("127.0.0.1", Port(0))
  # ANCHOR_END: ServerConnect
  srv.setupServer()
  srv.start()
  srv

proc stopServer*(srv: RpcWebSocketServer) {.async.} =
  srv.stop()
  await srv.closeWait()

proc main() {.raises: [JsonRpcError].} =
  let srv = startServer()
  runForever()

# Pass -d:jsonRpcExample to nim to run this
when defined(jsonRpcExample):
  main()

# ANCHOR_END: All
