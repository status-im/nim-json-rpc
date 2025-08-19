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
  std/sequtils,
  chronicles, httputils, chronos,
  chronos/apps/http/[httpserver, shttpserver],
  ../private/utils,
  ../errors,
  ../server

when tryImport json_serialization/pkg/chronos as jschronos:
  export jschronos
else:
  import json_serialization/std/net as jsnet
  export jsnet

export
  server, shttpserver

logScope:
  topics = "JSONRPC-HTTP-SERVER"

const
  JsonRpcIdent = "nim-json-rpc"

type
  # HttpAuthHook: handle CORS, JWT auth, etc. in HTTP header
  # before actual request processed
  # return value:
  # - nil: auth success, continue execution
  # - HttpResponse: could not authenticate, stop execution
  #   and return the response
  HttpAuthHook* =
    proc(request: HttpRequestRef): Future[HttpResponseRef] {.async: (raises: [CatchableError]).}

  # This inheritance arrangement is useful for
  # e.g. combo HTTP server
  RpcHttpHandler* = ref object of RpcServer
    maxChunkSize*: int

  RpcHttpServer* = ref object of RpcHttpHandler
    httpServers: seq[HttpServerRef]
    authHooks: seq[HttpAuthHook]

proc serveHTTP*(rpcServer: RpcHttpHandler, request: HttpRequestRef):
       Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  try:
    let req = await request.getBody()
    debug "Received JSON-RPC request",
      address = request.remote().valueOr(default(TransportAddress)),
      len = req.len

    let
      data = await rpcServer.route(req)
      chunkSize = rpcServer.maxChunkSize
      streamType =
        if data.len <= chunkSize:
          HttpResponseStreamType.Plain
        else:
          HttpResponseStreamType.Chunked
      response = request.getResponse()

    response.addHeader("Content-Type", "application/json")

    await response.prepare(streamType)
    let maxLen = data.len

    var len = data.len
    while len > chunkSize:
      await response.send(data[maxLen - len].unsafeAddr, chunkSize)
      len -= chunkSize

    if len > 0:
      await response.send(data[maxLen - len].unsafeAddr, len)

    await response.finish()
    response
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    debug "Internal error while processing JSON-RPC call", msg=exc.msg
    defaultResponse(exc)

proc processClientRpc(rpcServer: RpcHttpServer): HttpProcessCallback2 =
  return proc (req: RequestFence): Future[HttpResponseRef]
                  {.async: (raises: [CancelledError]).} =
    if not req.isOk():
      debug "Got invalid request", err = req.error()
      return defaultResponse()

    let request = req.get()
    # if hook result is not nil,
    # it means we should return immediately
    try:
      for hook in rpcServer.authHooks:
        let res = await hook(request)
        if not res.isNil:
          return res
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Internal error while processing JSON-RPC hook", msg=exc.msg
      return defaultResponse(exc)

    return await rpcServer.serveHTTP(request)

proc addHttpServer*(
    rpcServer: RpcHttpServer,
    address: TransportAddress,
    socketFlags: set[ServerFlags] = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
    serverUri = Uri(),
    serverIdent = "",
    maxConnections: int = -1,
    bufferSize: int = 4096,
    backlogSize: int = 100,
    httpHeadersTimeout = 10.seconds,
    maxHeadersSize: int = 8192,
    maxRequestBodySize: int = 1_048_576) {.raises: [JsonRpcError].} =
  let server = HttpServerRef.new(
      address,
      processClientRpc(rpcServer),
      {},
      socketFlags,
      serverUri, JsonRpcIdent, maxConnections, backlogSize,
      bufferSize, httpHeadersTimeout, maxHeadersSize, maxRequestBodySize
      ).valueOr:
    error "Failed to create server", address = $address,
                                     message = error
    raise newException(RpcBindError, "Unable to create server: " & $error)

  rpcServer.httpServers.add server

proc addSecureHttpServer*(
    rpcServer: RpcHttpServer,
    address: TransportAddress,
    tlsPrivateKey: TLSPrivateKey,
    tlsCertificate: TLSCertificate,
    socketFlags: set[ServerFlags] = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
    serverUri = Uri(),
    serverIdent: string = JsonRpcIdent,
    secureFlags: set[TLSFlags] = {},
    maxConnections: int = -1,
    backlogSize: int = 100,
    bufferSize: int = 4096,
    httpHeadersTimeout = 10.seconds,
    maxHeadersSize: int = 8192,
    maxRequestBodySize: int = 1_048_576) {.raises: [JsonRpcError].} =
  let server = SecureHttpServerRef.new(
      address,
      processClientRpc(rpcServer),
      tlsPrivateKey,
      tlsCertificate,
      {HttpServerFlags.Secure},
      socketFlags,
      serverUri, JsonRpcIdent, secureFlags, maxConnections, backlogSize,
      bufferSize, httpHeadersTimeout, maxHeadersSize, maxRequestBodySize
      ).valueOr:
    error "Failed to create server", address = $address,
                                     message = error
    raise newException(RpcBindError, "Unable to create server: " & $error)

  rpcServer.httpServers.add server

proc addHttpServers*(server: RpcHttpServer,
                     addresses: openArray[TransportAddress]) {.raises: [JsonRpcError].} =
  ## Start a server on at least one of the given addresses, or raise
  if addresses.len == 0:
    return

  var lastExc: ref JsonRpcError
  for item in addresses:
    try:
      server.addHttpServer(item)
    except JsonRpcError as exc:
      lastExc = exc
  if server.httpServers.len == 0:
    raise lastExc

proc addSecureHttpServers*(server: RpcHttpServer,
                           addresses: openArray[TransportAddress],
                           tlsPrivateKey: TLSPrivateKey,
                           tlsCertificate: TLSCertificate) {.raises: [JsonRpcError].} =
  ## Start a server on at least one of the given addresses, or raise
  if addresses.len == 0:
    return

  var lastExc: ref JsonRpcError
  for item in addresses:
    try:
      server.addSecureHttpServer(item, tlsPrivateKey, tlsCertificate)
    except JsonRpcError as exc:
      lastExc = exc
  if server.httpServers.len == 0:
    raise lastExc

proc addHttpServer*(server: RpcHttpServer, address: string) {.raises: [JsonRpcError].} =
  ## Create new server and assign it to addresses ``addresses``.
  addHttpServers(server, toSeq(resolveIP([address])))

proc addSecureHttpServer*(server: RpcHttpServer,
                          address: string,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate) {.raises: [JsonRpcError].} =
  addSecureHttpServers(server, toSeq(resolveIP([address])), tlsPrivateKey, tlsCertificate)

proc addHttpServers*(server: RpcHttpServer, addresses: openArray[string]) {.raises: [JsonRpcError].} =
  addHttpServers(server, toSeq(resolveIP(addresses)))

proc addHttpServer*(server: RpcHttpServer, address: string, port: Port) {.raises: [JsonRpcError].} =
  addHttpServers(server, toSeq(resolveIP(address, port)))

proc addSecureHttpServer*(server: RpcHttpServer,
                          address: string,
                          port: Port,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate) {.raises: [JsonRpcError].} =
  addSecureHttpServers(server, toSeq(resolveIP(address, port)), tlsPrivateKey, tlsCertificate)

proc new*(T: type RpcHttpServer, authHooks: seq[HttpAuthHook] = @[]): T =
  T(router: RpcRouter.init(), httpServers: @[], authHooks: authHooks, maxChunkSize: 8192)

proc new*(T: type RpcHttpServer, router: RpcRouter, authHooks: seq[HttpAuthHook] = @[]): T =
  T(router: router, httpServers: @[], authHooks: authHooks, maxChunkSize: 8192)

proc newRpcHttpServer*(authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  RpcHttpServer.new(authHooks)

proc newRpcHttpServer*(router: RpcRouter, authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  RpcHttpServer.new(router, authHooks)

proc newRpcHttpServer*(addresses: openArray[TransportAddress], authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer {.raises: [JsonRpcError].} =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(authHooks)
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[string], authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer {.raises: [JsonRpcError].} =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(authHooks)
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[string], router: RpcRouter, authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer {.raises: [JsonRpcError].} =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(router, authHooks)
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[TransportAddress], router: RpcRouter, authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer {.raises: [JsonRpcError].} =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(router, authHooks)
  result.addHttpServers(addresses)

proc start*(server: RpcHttpServer) =
  ## Start the RPC server.
  for item in server.httpServers:
    info "Starting JSON-RPC HTTP server", url = item.baseUri
    item.start()

proc stop*(server: RpcHttpServer) {.async.} =
  ## Stop the RPC server.
  for item in server.httpServers:
    await item.stop()
    info "Stopped JSON-RPC HTTP server", url = item.baseUri

proc closeWait*(server: RpcHttpServer) {.async.} =
  ## Cleanup resources of RPC server.
  for item in server.httpServers:
    await item.closeWait()

proc localAddress*(server: RpcHttpServer): seq[TransportAddress] =
  for item in server.httpServers:
    result.add item.instance.localAddress()

proc setMaxChunkSize*(server: RpcHttpServer, maxChunkSize: int) =
  server.maxChunkSize = maxChunkSize
