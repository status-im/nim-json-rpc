import
  chronicles, httputils, chronos, websock/websock,
  websock/extensions/compression/deflate,
  stew/byteutils,
  ".."/[errors, server]

export server

logScope:
  topics = "JSONRPC-WS-SERVER"

type
  RpcWebSocketServer* = ref object of RpcServer
    server: StreamServer
    wsserver: WSServer

proc handleRequest(rpc: RpcWebSocketServer, request: HttpRequest) {.async.} =
  trace "Handling request:", uri = request.uri.path
  trace "Initiating web socket connection."
  try:
    let server = rpc.wsserver
    let ws = await server.handleRequest(request)
    if ws.readyState != Open:
      error "Failed to open websocket connection"
      return

    trace "Websocket handshake completed"
    while ws.readyState != ReadyState.Closed:
      let recvData = await ws.recvMsg()
      trace "Client message: ", size = recvData.len, binary = ws.binary

      if ws.readyState == ReadyState.Closed:
        # if session already terminated by peer,
        # no need to send response
        break

      if recvData.len == 0:
        await ws.close(
          reason = "cannot process zero length message"
        )
        break

      let future = rpc.route(string.fromBytes(recvData))
      yield future
      if future.failed:
        debug "Internal error, while processing RPC call",
              address = $request.uri
        await ws.close(
          reason = "Internal error, while processing RPC call"
        )
        break

      var data = future.read()
      trace "RPC result has been sent", address = $request.uri

      await ws.send(data)

  except WebSocketError as exc:
    error "WebSocket error:", exception = exc.msg

proc initWebsocket(rpc: RpcWebSocketServer, compression: bool) =
  if compression:
    let deflateFactory = deflateFactory()
    rpc.wsserver = WSServer.new(factories = [deflateFactory])
  else:
    rpc.wsserver = WSServer.new()

proc newRpcWebSocketServer*(
  address: TransportAddress,
  compression: bool = false,
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay,
    ServerFlags.ReuseAddr}): RpcWebSocketServer =

  var server = new(RpcWebSocketServer)
  proc processCallback(request: HttpRequest): Future[void] =
    handleRequest(server, request)

  server.initWebsocket(compression)
  server.server = HttpServer.create(
    address,
    processCallback,
    flags
  )

  server

proc newRpcWebSocketServer*(
  host: string,
  port: Port,
  compression: bool = false,
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay,
    ServerFlags.ReuseAddr}): RpcWebSocketServer =

  newRpcWebSocketServer(
    initTAddress(host, port),
    compression,
    flags
  )

proc newRpcWebSocketServer*(
  address: TransportAddress,
  tlsPrivateKey: TLSPrivateKey,
  tlsCertificate: TLSCertificate,
  compression: bool = false,
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay,
    ServerFlags.ReuseAddr},
  tlsFlags: set[TLSFlags] = {},
  tlsMinVersion = TLSVersion.TLS12,
  tlsMaxVersion = TLSVersion.TLS12): RpcWebSocketServer =

  var server = new(RpcWebSocketServer)
  proc processCallback(request: HttpRequest): Future[void] =
    handleRequest(server, request)

  server.initWebsocket(compression)
  server.server = TlsHttpServer.create(
    address,
    tlsPrivateKey,
    tlsCertificate,
    processCallback,
    flags,
    tlsFlags,
    tlsMinVersion,
    tlsMaxVersion
  )

  server

proc newRpcWebSocketServer*(
  host: string,
  port: Port,
  tlsPrivateKey: TLSPrivateKey,
  tlsCertificate: TLSCertificate,
  compression: bool = false,
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay,
    ServerFlags.ReuseAddr},
  tlsFlags: set[TLSFlags] = {},
  tlsMinVersion = TLSVersion.TLS12,
  tlsMaxVersion = TLSVersion.TLS12): RpcWebSocketServer =

  newRpcWebSocketServer(
    initTAddress(host, port),
    tlsPrivateKey,
    tlsCertificate,
    compression,
    flags,
    tlsFlags,
    tlsMinVersion,
    tlsMaxVersion
  )

proc start*(server: RpcWebSocketServer) =
  ## Start the RPC server.
  notice "WS RPC server started", address = server.server.local
  server.server.start()

proc stop*(server: RpcWebSocketServer) =
  ## Stop the RPC server.
  notice "WS RPC server stopped", address = server.server.local
  server.server.stop()

proc close*(server: RpcWebSocketServer) =
  ## Cleanup resources of RPC server.
  server.server.close()

proc closeWait*(server: RpcWebSocketServer) {.async.} =
  ## Cleanup resources of RPC server.
  await server.server.closeWait()
