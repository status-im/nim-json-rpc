# ANCHOR: All
# websocket_client.nim

{.push gcsafe, raises: [].}

import json_rpc/rpcclient
import ./[rpc_format, websocket_server]

createRpcSigsFromNim(RpcClient, RpcConv):
  proc hello(input: string): string

proc main() {.async.} =
  let srv = startServer()
  defer: await srv.stopServer()

  # ANCHOR: ClientConnect
  let client = newRpcWebSocketClient()
  await client.connect("ws://" & $srv.localAddress())
  # ANCHOR_END: ClientConnect
  defer: await client.close()

  let resp1 = await client.hello("Daisy")
  doAssert resp1 == "Hello Daisy"

when isMainModule:
  waitFor main()
  echo "ok"

# ANCHOR_END: All
