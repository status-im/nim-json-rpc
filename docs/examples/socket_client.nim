# ANCHOR: All
# socket_client.nim

{.push gcsafe, raises: [].}

import json_rpc/rpcclient
import ./[rpc_format, socket_server]

createRpcSigsFromNim(RpcClient, RpcConv):
  proc hello(input: string): string

proc main() {.async.} =
  let srv = startServer()
  defer: await srv.stopServer()

  # ANCHOR: ClientConnect
  const framing = Framing.lengthHeaderBE32()
  let client = newRpcSocketClient(framing = framing)
  await client.connect(srv.localAddress()[0])
  # ANCHOR_END: ClientConnect
  defer: await client.close()

  let resp1 = await client.hello("Daisy")
  doAssert resp1 == "Hello Daisy"

when isMainModule:
  waitFor main()
  echo "ok"

# ANCHOR_END: All
