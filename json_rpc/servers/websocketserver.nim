# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronicles, chronos, websock/[websock, types],
  websock/extensions/compression/deflate,
  stew/byteutils, json_serialization/std/net,
  ".."/[server]

export server, net

logScope:
  topics = "JSONRPC-WS-SERVER"

type
  # WsAuthHook: handle CORS, JWT auth, etc. in HTTP header
  # before actual request processed
  # return value:
  # - true: auth success, continue execution
  # - false: could not authenticate, stop execution
  #   and return the response
  WsAuthHook* = proc(request: HttpRequest): Future[bool]
                  {.gcsafe, raises: [Defect, CatchableError].}

  RpcWebSocketServer* = ref object of RpcServer
    server: StreamServer
    wsserver: WSServer
    authHooks: seq[WsAuthHook]

proc handleRequest(rpc: RpcWebSocketServer, request: HttpRequest) {.async.} =
  trace "Handling request:", uri = request.uri.path
  trace "Initiating web socket connection."

  # if hook result is false,
  # it means we should return immediately
  for hook in rpc.authHooks:
    let res = await hook(request)
    if not res:
      return

  try:
    let server = rpc.wsserver
    let ws = await server.handleRequest(request)
    if ws.readyState != ReadyState.Open:
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

proc initWebsocket(rpc: RpcWebSocketServer, compression: bool,
                   authHooks: seq[WsAuthHook],
                   rng: ref HmacDrbgContext) =
  if compression:
    let deflateFactory = deflateFactory()
    rpc.wsserver = WSServer.new(factories = [deflateFactory], rng = rng)
  else:
    rpc.wsserver = WSServer.new(rng = rng)
  rpc.authHooks = authHooks

proc newRpcWebSocketServer*(
  address: TransportAddress,
  compression: bool = false,
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay,ServerFlags.ReuseAddr},
  authHooks: seq[WsAuthHook] = @[],
  rng = HmacDrbgContext.new()): RpcWebSocketServer =

  var server = new(RpcWebSocketServer)
  proc processCallback(request: HttpRequest): Future[void] =
    handleRequest(server, request)

  server.initWebsocket(compression, authHooks, rng)
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
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
  authHooks: seq[WsAuthHook] = @[],
  rng = HmacDrbgContext.new()): RpcWebSocketServer =

  newRpcWebSocketServer(
    initTAddress(host, port),
    compression,
    flags,
    authHooks,
    rng
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
  tlsMaxVersion = TLSVersion.TLS12,
  authHooks: seq[WsAuthHook] = @[],
  rng = HmacDrbgContext.new()): RpcWebSocketServer =

  var server = new(RpcWebSocketServer)
  proc processCallback(request: HttpRequest): Future[void] =
    handleRequest(server, request)

  server.initWebsocket(compression, authHooks, rng)
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
  tlsMaxVersion = TLSVersion.TLS12,
  authHooks: seq[WsAuthHook] = @[],
  rng = HmacDrbgContext.new()): RpcWebSocketServer =

  newRpcWebSocketServer(
    initTAddress(host, port),
    tlsPrivateKey,
    tlsCertificate,
    compression,
    flags,
    tlsFlags,
    tlsMinVersion,
    tlsMaxVersion,
    authHooks,
    rng
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

proc localAddress*(server: RpcWebSocketServer): TransportAddress = 
  server.server.localAddress()
