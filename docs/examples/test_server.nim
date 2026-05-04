# ANCHOR: All
# test_server.nim

{.push gcsafe, raises: [].}

import json_rpc/rpcserver
import ./rpc_format

proc setupServer(srv: RpcServer) =
  srv.rpc(RpcConv):
    proc hello(input: string): string =
      "Hello " & input

proc main {.async.} =
  let srv = newRpcHttpServer(["127.0.0.1:0"])
  srv.setupServer()
  # ANCHOR: TestExecute
  let resp = await srv.executeMethod("hello", %* ["Daisy"], RpcConv)
  doAssert RpcConv.decode(resp, string) == "Hello Daisy"
  # ANCHOR_END: TestExecute

when isMainModule:
  waitFor main()
  echo "ok"

# ANCHOR_END: All
