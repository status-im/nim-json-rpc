# ANCHOR: All
# socket_server.nim

{.push gcsafe, raises: [].}

import json_rpc/rpcserver
import ./rpc_format

export rpcserver

proc setupServer(srv: RpcServer) =
  srv.rpc(RpcConv):
    proc hello(input: string): string =
      "Hello " & input

proc startServer*(): RpcSocketServer {.raises: [JsonRpcError].} =
  # ANCHOR: ServerConnect
  const framing = Framing.lengthHeaderBE32()
  let srv = newRpcSocketServer(["127.0.0.1:0"], framing = framing)
  # ANCHOR_END: ServerConnect
  srv.setupServer()
  srv.start()
  srv

proc stopServer*(srv: RpcSocketServer) {.async.} =
  srv.stop()
  await srv.closeWait()

proc main() {.raises: [JsonRpcError].} =
  let srv = startServer()
  runForever()

# Pass -d:jsonRpcExample to nim to run this
when defined(jsonRpcExample):
  main()

# ANCHOR_END: All
