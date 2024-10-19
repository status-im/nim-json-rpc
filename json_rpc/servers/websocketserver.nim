# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  chronicles, chronos, websock/[websock, types],
  websock/extensions/compression/deflate,
  stew/byteutils, json_serialization/std/net,
  ".."/[errors, server]

export errors, server, net

logScope:
  topics = "JSONRPC-WS-SERVER"

type
  # WsAuthHook: handle CORS, JWT auth, etc. in HTTP header
  # before actual request processed
  # return value:
  # - true: auth success, continue execution
  # - false: could not authenticate, stop execution
  #   and return the response
  WsAuthHook* = proc(request: HttpRequest): Future[bool] {.async.}

  # This inheritance arrangement is useful for
  # e.g. combo HTTP server
  RpcWebSocketHandler* = ref object of RpcServer
    wsserver*: WSServer

  RpcWebSocketServer* = ref object of RpcWebSocketHandler
    server: StreamServer
    authHooks: seq[WsAuthHook]

proc serveHTTP*(rpc: RpcWebSocketHandler, request: HttpRequest)
                  {.async: (raises: [CancelledError]).} =
  try:
    let server = rpc.wsserver
    let ws = await server.handleRequest(request)
    if ws.readyState != ReadyState.Open:
      error "Failed to open websocket connection"
      return

    trace "Websocket handshake completed"
    while ws.readyState != ReadyState.Closed:
      let req = await ws.recvMsg()
      debug "Received JSON-RPC request", len = req.len

      if ws.readyState == ReadyState.Closed:
        # if session already terminated by peer,
        # no need to send response
        break

      if req.len == 0:
        await ws.close(
          reason = "cannot process zero length message"
        )
        break

      let data = try:
          await rpc.route(string.fromBytes(req))
        except CatchableError as exc:
          debug "Internal error, while processing RPC call",
            address = $request.uri
          await ws.close(
            reason = "Internal error, while processing RPC call: " & exc.msg
          )
          break

      trace "RPC result has been sent", address = $request.uri
      await ws.send(data)

  except WebSocketError as exc:
    error "WebSocket error:", exception = exc.msg

  except CancelledError as exc:
    raise exc

  except CatchableError as exc:
    debug "Something error", msg=exc.msg

proc handleRequest(rpc: RpcWebSocketServer, request: HttpRequest)
                    {.async: (raises: [CancelledError]).} =
  trace "Handling request:", uri = request.uri.path
  trace "Initiating web socket connection."

  # if hook result is false,
  # it means we should return immediately
  try:
    for hook in rpc.authHooks:
      let res = await hook(request)
      if not res:
        return
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    debug "Internal error while processing JSON-RPC hook", msg=exc.msg
    try:
      await request.sendResponse(Http503,
        data = "",
        content = "Internal error, processing JSON-RPC hook: " & exc.msg)
      return
    except CatchableError as exc:
      debug "Something error", msg=exc.msg
      return

  await rpc.serveHTTP(request)

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
  rng = HmacDrbgContext.new()): RpcWebSocketServer {.raises: [JsonRpcError].} =

  var server = new(RpcWebSocketServer)
  proc processCallback(request: HttpRequest): Future[void] =
    handleRequest(server, request)

  server.initWebsocket(compression, authHooks, rng)
  try:
    server.server = HttpServer.create(
      address,
      processCallback,
      flags
    )
  except CatchableError as exc:
    raise (ref RpcBindError)(msg: "Unable to create server: " & exc.msg, parent: exc)

  server

proc newRpcWebSocketServer*(
  host: string,
  port: Port,
  compression: bool = false,
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
  authHooks: seq[WsAuthHook] = @[],
  rng = HmacDrbgContext.new()): RpcWebSocketServer {.raises: [JsonRpcError].} =

  try:
    newRpcWebSocketServer(
      initTAddress(host, port),
      compression,
      flags,
      authHooks,
      rng
    )
  except TransportError as exc:
    raise (ref RpcBindError)(msg: "Unable to create server: " & exc.msg, parent: exc)

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
  rng = HmacDrbgContext.new()): RpcWebSocketServer {.raises: [JsonRpcError].} =

  var server = new(RpcWebSocketServer)
  proc processCallback(request: HttpRequest): Future[void] =
    handleRequest(server, request)

  server.initWebsocket(compression, authHooks, rng)
  try:
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
  except CatchableError as exc:
    raise (ref RpcBindError)(msg: "Unable to create server: " & exc.msg, parent: exc)

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
  rng = HmacDrbgContext.new()): RpcWebSocketServer {.raises: [JsonRpcError].} =

  try:
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
  except TransportError as exc:
    raise (ref RpcBindError)(msg: "Unable to create server: " & exc.msg, parent: exc)

proc start*(server: RpcWebSocketServer) {.raises: [JsonRpcError].} =
  ## Start the RPC server.
  try:
    info "Starting JSON-RPC WebSocket server", address = server.server.local
    server.server.start()
  except TransportOsError as exc:
    raise (ref RpcBindError)(msg: "Unable to start server: " & exc.msg, parent: exc)

proc stop*(server: RpcWebSocketServer) =
  ## Stop the RPC server.
  try:
    server.server.stop()
    notice "Stopped JSON-RPC WebSocket server", address = server.server.local
  except TransportOsError as exc:
    warn "Could not stop JSON-RPC WebSocket server", err = exc.msg

proc close*(server: RpcWebSocketServer) =
  ## Cleanup resources of RPC server.
  server.server.close()

proc closeWait*(server: RpcWebSocketServer) {.async.} =
  ## Cleanup resources of RPC server.
  await server.server.closeWait()

proc localAddress*(server: RpcWebSocketServer): TransportAddress =
  server.server.localAddress()
