# ANCHOR: All
{.push gcsafe, raises: [].}

import os
import json_rpc/rpcclient
import ./[rpc_format, http_server]

# ANCHOR: ClientFileSigs
const sigsFilePath = currentSourcePath().parentDir / "client_sigs.nim"
createRpcSigs(RpcClient, sigsFilePath, RpcConv)
# ANCHOR_END: ClientFileSigs

# ANCHOR: ClientSingleSig
createSingleRpcSig(RpcClient, "sayBye", RpcConv):
  proc bye(name: string): string
# ANCHOR_END: ClientSingleSig

proc main() {.async.} =
  let srv = startServer()
  let client = newRpcHttpClient()
  await client.connect("http://" & $srv.localAddress()[0])
  let resp1 = await client.hello("Daisy")
  let resp2 = await client.sayBye("Daisy")
  doAssert resp1 == "Hello Daisy"
  doAssert resp2 == "Bye Daisy"
  await client.close()
  await srv.stopServer()

when isMainModule:
  waitFor main()
  echo "ok"

# ANCHOR_END: All
