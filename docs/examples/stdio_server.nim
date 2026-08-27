# ANCHOR: All
# stdio_server.nim

{.push gcsafe, raises: [].}

# ANCHOR: ServerLogging
# Standard output carries the protocol, so chronicles must not write there.
# Checking the setting here turns a corrupted message stream into a build
# error - build this program with:
#
#   -d:"chronicles_sinks=textlines[stderr]"
proc logsToStderr(): bool =
  const chronicles_sinks {.strdefine.} = ""
  chronicles_sinks == "textlines[stderr]"

when not logsToStderr():
  {.error: "stdio transport requires -d:chronicles_sinks=textlines[stderr]".}
# ANCHOR_END: ServerLogging

import json_rpc/servers/stdioserver
import ./rpc_format

export stdioserver

proc setupServer(srv: RpcStdioServer) =
  srv.rpc(RpcConv):
    proc hello(input: string): string =
      "Hello " & input

proc main() {.raises: [].} =
  # ANCHOR: ServerConnect
  # `Content-Length` framing is what LSP and MCP peers speak over stdio
  let srv = newRpcStdioServer(framing = StdioFraming.httpHeader())
  # ANCHOR_END: ServerConnect

  srv.setupServer()

  # ANCHOR: ServerStart
  # Serves until the peer closes standard input, which is the whole lifetime
  # of a process launched to speak JSON-RPC over stdio
  waitFor srv.serve()
  # ANCHOR_END: ServerStart

when isMainModule:
  main()

# ANCHOR_END: All
