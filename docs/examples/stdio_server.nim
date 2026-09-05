# ANCHOR: All
# stdio_server.nim

{.push gcsafe, raises: [].}

import json_rpc/servers/stdioserver
import ./rpc_format

export stdioserver

proc setupServer(srv: RpcStdioServer) =
  srv.rpc(RpcConv):
    proc hello(input: string): string =
      "Hello " & input

proc main() {.raises: [CancelledError, JsonRpcError].} =
  # ANCHOR: ServerConnect
  let srv = newRpcStdioServer(framing = StdioFraming.httpHeader())
  # ANCHOR_END: ServerConnect

  srv.setupServer()

  # ANCHOR: ServerStart
  waitFor srv.serve()
  # ANCHOR_END: ServerStart

when isMainModule:
  main()

# ANCHOR_END: All
