{.push raises: [Defect].}

import 
  ./servers/[httpserver],
  ./clients/[httpclient]

type RpcHttpProxy* = ref object of RootRef
  rpcHttpClient*: RpcHttpClient
  rpcHttpServer*: RpcHttpServer

proc proxyCall(client: RpcHttpClient, name: string): RpcProc =
  return proc (params: JsonNode): Future[StringOfJson] {.async.} =
          let res = await client.call(name, params)
          return StringOfJson($res)

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
 proxy.rpcHttpServer.register(methodName, proxyCall(proxy.rpcHttpClient, methodName))

proc stop*(rpcHttpProxy: RpcHttpProxy) {.raises: [Defect, CatchableError].} =
  rpcHttpProxy.rpcHttpServer.stop()

proc closeWait*(rpcHttpProxy: RpcHttpProxy) {.async.} =
  await rpcHttpProxy.rpcHttpServer.closeWait()