# ANCHOR: All
# http_client.nim

{.push gcsafe, raises: [].}

import json_rpc/rpcclient
import ./[rpc_format, http_server]

# ANCHOR: RpcHello
createRpcSigsFromNim(RpcClient, RpcConv):
  proc hello(input: string): string
  # ANCHOR_END: RpcHello
  proc bye(name: string): string
  # ANCHOR: RpcSmile
  proc `🙂`(input: string): string
  # ANCHOR_END: RpcSmile
  proc notif()
  proc justHello(): string
  proc teaPot()

proc main() {.async.} =
  let srv = startServer()
  defer:
    await srv.stopServer()

  # ANCHOR: ClientConnect
  let client = newRpcHttpClient()
  await client.connect("http://" & $srv.localAddress()[0])
  # ANCHOR_END: ClientConnect
  defer:
    # ANCHOR: ClientDisconnect
    await client.close()
    # ANCHOR_END: ClientDisconnect

  # ANCHOR: ClientRequest
  let resp1 = await client.hello("Daisy")
  # ANCHOR_END: ClientRequest
  doAssert resp1 == "Hello Daisy"

  # ANCHOR: ClientRequestRuntime
  let resp2 = await client.call("hello", %* ["Daisy"], RpcConv)
  # ANCHOR_END: ClientRequestRuntime
  # ANCHOR: ClientResponseDecode
  doAssert RpcConv.decode(resp2, string) == "Hello Daisy"
  # ANCHOR_END: ClientResponseDecode

  # ANCHOR: ClientRequestNamedRuntime
  let resp3 = await client.call("hello", %* {"input": "Daisy"}, RpcConv)
  # ANCHOR_END: ClientRequestNamedRuntime
  doAssert RpcConv.decode(resp3, string) == "Hello Daisy"

  # ANCHOR: ClientRequestNoParamsRuntime
  let resp4 = await client.call("justHello", %* [], RpcConv)
  # ANCHOR_END: ClientRequestNoParamsRuntime
  doAssert RpcConv.decode(resp4, string) == "Hello"

  let resp5 = await client.bye("Daisy")
  doAssert resp5 == "Bye Daisy"

  let resp6 = await client.`🙂`("Daisy")
  doAssert resp6 == "🙂 Daisy"


  # ANCHOR: ClientBatch
  let batch = client.prepareBatch()
  batch.hello("Daisy")
  batch.`🙂`("Daisy")
  let batchRes = await batch.send()
  # ANCHOR_END: ClientBatch
  # ANCHOR: ClientBatchResult
  let r = batchRes.tryGet()
  doAssert r[0].error.isNone
  doAssert RpcConv.decode(r[0].result, string) == "Hello Daisy"
  doAssert r[1].error.isNone
  doAssert RpcConv.decode(r[1].result, string) == "🙂 Daisy"
  # ANCHOR_END: ClientBatchResult

  # ANCHOR: ClientNotification
  await client.notify("notif", RequestParamsTx())
  # ANCHOR_END: ClientNotification

  # ANCHOR: ClientTeaPot
  try:
    discard await client.teaPot()
    doAssert false
  except JsonRpcError as err:
    doAssert err.msg == """{"code":418,"message":"I'm a teapot"}"""
  # ANCHOR_END: ClientTeaPot

when isMainModule:
  waitFor main()
  echo "ok"

# ANCHOR_END: All
