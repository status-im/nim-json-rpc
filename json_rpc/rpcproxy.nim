{.push raises: [Defect].}

import 
  ./servers/[httpserver],
  ./clients/[httpclient]

type RpcHttpProxy* = ref object of RootRef
  rpcHttpClient: RpcHttpClient
  rpcHttpServer: RpcHttpServer

proc proxyCall(client: RpcHttpClient): ProxyCall =
  return proc (name: string, params: JsonNode): Future[Response] = client.call(name, params)

proc new*(T: type RpcHttpProxy, listenAddresses: openArray[string]): T {.raises: [Defect, CatchableError].}= 
  let client = newRpcHttpClient()
  let router = RpcRouter.init()
  T(rpcHttpClient: client, rpcHttpServer: newRpcHttpServer(listenAddresses, router))

proc newRpcHttpProxy*(listenAddresses: openArray[string]): RpcHttpProxy {.raises: [Defect, CatchableError].} =
  RpcHttpProxy.new(listenAddresses)

proc start*(proxy:RpcHttpProxy, proxyServerUrl: string) {.async.} =
  proxy.rpcHttpServer.start()
  await proxy.rpcHttpClient.connect(proxyServerUrl)

proc start*(proxy:RpcHttpProxy, proxyServerAddress: string, proxyServerPort: Port) {.async.} =
  proxy.rpcHttpServer.start()
  await proxy.rpcHttpClient.connect(proxyServerAddress, proxyServerPort)

template rpc*(server: RpcHttpProxy, path: string, body: untyped): untyped =
  server.rpcHttpServer.rpc(path, body)

proc registerProxyMethod*(proxy: var RpcHttpProxy, methodName: string) {.raises: [Defect, CatchableError].} = 
 proxy.rpcHttpServer.registerProxyCall(methodName, proxyCall(proxy.rpcHttpClient))

proc stop*(rpcHttpProxy: RpcHttpProxy) {.raises: [Defect, CatchableError].} =
  rpcHttpProxy.rpcHttpServer.stop()

proc closeWait*(rpcHttpProxy: RpcHttpProxy) {.async.} =
  await rpcHttpProxy.rpcHttpServer.closeWait()