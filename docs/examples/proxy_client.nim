# ANCHOR: All
# proxy_client.nim

{.push gcsafe, raises: [].}

import json_rpc/rpcclient
import ./[rpc_format, http_server, proxy_server]

createRpcSigsFromNim(RpcClient, RpcConv):
  proc hello(input: string): string
  proc bye(input: string): string

proc main() {.async.} =
  let srv = startServer()
  defer: await srv.stopServer()

  let proxy = await startProxy("http://" & $srv.localAddress()[0])
  defer: await proxy.stopProxy()

  let client = newRpcHttpClient()
  await client.connect("http://" & $proxy.localAddress()[0])
  defer: await client.close()

  let resp1 = await client.hello("Daisy")
  doAssert resp1 == "Hello Daisy"
  let resp2 = await client.bye("Daisy")
  doAssert resp2 == "Proxy Bye Daisy"

when isMainModule:
  waitFor main()
  echo "ok"

# ANCHOR_END: All
