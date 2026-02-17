# ANCHOR: All
# proxy_server.nim

{.push gcsafe, raises: [].}

import json_rpc/[rpcserver, rpcproxy]
import ./rpc_format

export rpcproxy

proc setupServer(proxy: var RpcProxy) =
  # ANCHOR: ProxyHello
  proxy.registerProxyMethod("hello")
  # ANCHOR_END: ProxyHello

  # ANCHOR: RpcBye
  proxy.rpc(RpcConv):
    proc bye(input: string): string =
      "Proxy Bye " & input
  # ANCHOR_END: RpcBye

proc startProxy*(srvUrl: string): Future[RpcProxy] {.async.} =
  # ANCHOR: ServerConnect
  var proxy = RpcProxy.new(["127.0.0.1:0"], getHttpClientConfig(srvUrl))
  # ANCHOR_END: ServerConnect
  proxy.setupServer()
  # ANCHOR: ServerStart
  await proxy.start()
  # ANCHOR_END: ServerStart
  proxy

proc stopProxy*(proxy: RpcProxy) {.async.} =
  # ANCHOR: ServerDisconnect
  await proxy.stop()
  await proxy.closeWait()
  # ANCHOR_END: ServerDisconnect

proc main() {.raises: [CatchableError].} =
  # Compile with -d:srvUrl="http://hostname:port"
  const srvUrl {.strdefine.}: string = ""
  let proxy = waitFor startProxy(srvUrl)
  runForever()

# Compile with -d:jsonRpcExample to run this
when defined(jsonRpcExample):
  main()

# ANCHOR_END: All
