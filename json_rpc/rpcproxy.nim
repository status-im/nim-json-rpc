{.push raises: [Defect].}

import
   pkg/websock/websock,
  ./servers/[httpserver],
  ./clients/[httpclient, websocketclient]

type
  ClientKind* = enum
    Http,
    WebSocket

  ClientConfig* = object
    case kind*: ClientKind
    of Http:
      httpUri*: string
    of WebSocket:
      wsUri*: string
      compression*: bool
      flags*: set[TLSFlags]

  RpcProxy* = ref object of RootRef
    rpcHttpServer*: RpcHttpServer
    case kind*: ClientKind
    of Http:
      httpUri*: string
      httpClient*: RpcHttpClient
    of WebSocket:
      wsUri*: string
      webSocketClient*: RpcWebSocketClient
      compression*: bool
      flags*: set[TLSFlags]

# TODO Add validations that provided uri-s are correct https/wss uri and retrun
#  Result[string, ClientConfig]
proc getHttpClientConfig*(uri: string): ClientConfig =
  ClientConfig(kind: Http, httpUri: uri)

proc getWebSocketClientConfig*(
              uri: string,
              compression: bool = false,
              flags: set[TLSFlags] = {
                NoVerifyHost, NoVerifyServerName}): ClientConfig =
  ClientConfig(kind: WebSocket, wsUri: uri, compression: compression, flags: flags)

proc proxyCall(client: RpcClient, name: string): RpcProc =
  return proc (params: JsonNode): Future[RpcResult] {.async, gcsafe, raises: [Defect, CatchableError, Exception].} =
           let res = await client.call(name, params)
           return some(StringOfJson($res))

proc getClient(proxy: RpcProxy): RpcClient =
  case proxy.kind
  of Http:
    proxy.httpClient
  of WebSocket:
    proxy.webSocketClient

proc new*(T: type RpcProxy, server: RpcHttpServer, cfg: ClientConfig): T =
  case cfg.kind
  of Http:
    let client = newRpcHttpClient()
    return T(rpcHttpServer: server, kind: Http, httpUri: cfg.httpUri, httpClient: client)
  of WebSocket:
    let client = newRpcWebSocketClient()
    return T(
              rpcHttpServer: server,
              kind: WebSocket,
              wsUri: cfg.wsUri,
              webSocketClient: client,
              compression: cfg.compression,
              flags: cfg.flags
            )

proc new*(T: type RpcProxy, listenAddresses: openArray[TransportAddress], cfg: ClientConfig): T {.raises: [Defect, CatchableError].} =
  RpcProxy.new(newRpcHttpServer(listenAddresses, RpcRouter.init()), cfg)

proc new*(T: type RpcProxy, listenAddresses: openArray[string], cfg: ClientConfig): T {.raises: [Defect, CatchableError].} =
  RpcProxy.new(newRpcHttpServer(listenAddresses, RpcRouter.init()), cfg)

proc connectToProxy(proxy: RpcProxy): Future[void] =
  case proxy.kind
  of Http:
    return proxy.httpClient.connect(proxy.httpUri)
  of WebSocket:
    return proxy.webSocketClient.connect(proxy.wsUri, proxy.compression, proxy.flags)

proc start*(proxy: RpcProxy) {.async.} =
  proxy.rpcHttpServer.start()
  await proxy.connectToProxy()

template rpc*(server: RpcProxy, path: string, body: untyped): untyped =
  server.rpcHttpServer.rpc(path, body)

proc registerProxyMethod*(proxy: var RpcProxy, methodName: string) {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  try:
    proxy.rpcHttpServer.register(methodName, proxyCall(proxy.getClient(), methodName))
  except CatchableError as err:
    # Adding proc type to table gives invalid exception tracking, see Nim bug: https://github.com/nim-lang/Nim/issues/18376
    raiseAssert err.msg

proc stop*(proxy: RpcProxy) {.async.} =
  await proxy.getClient().close()
  await proxy.rpcHttpServer.stop()

proc closeWait*(proxy: RpcProxy) {.async.} =
  await proxy.rpcHttpServer.closeWait()
