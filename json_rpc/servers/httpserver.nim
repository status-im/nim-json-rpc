# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  stew/byteutils,
  chronicles, httputils, chronos,
  chronos/apps/http/[httpserver, shttpserver],
  ../private/errors,
  ../server

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
  HttpAuthHook* = proc(request: HttpRequestRef): Future[HttpResponseRef]
                  {.gcsafe, raises: [Defect, CatchableError].}

  RpcHttpServer* = ref object of RpcServer
    httpServers: seq[HttpServerRef]
    authHooks: seq[HttpAuthHook]

proc processClientRpc(rpcServer: RpcHttpServer): HttpProcessCallback2 =
  return proc (req: RequestFence): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    if not req.isOk():
      return defaultResponse()

    let request = req.get()
    # if hook result is not nil,
    # it means we should return immediately
    try:
      for hook in rpcServer.authHooks:
        let res = await hook(request)
        if not res.isNil:
          return res
    except CatchableError as exc:
      error "Internal error while processing JSON-RPC hook", msg=exc.msg
      try:
        return await request.respond(
          Http503,
          "Internal error while processing JSON-RPC hook: " & exc.msg)
      except HttpWriteError as exc:
        error "Something error", msg=exc.msg
        return defaultResponse()

    let
      headers = HttpTable.init([("Content-Type",
                                 "application/json; charset=utf-8")])
    try:
      let
        body = await request.getBody()

        data = await rpcServer.route(string.fromBytes(body))
        res = await request.respond(Http200, data, headers)

      trace "JSON-RPC result has been sent"
      return res
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "Internal error while processing JSON-RPC call"
      try:
        return await request.respond(
          Http503,
          "Internal error while processing JSON-RPC call: " & exc.msg)
      except HttpWriteError as exc:
        error "Something error", msg=exc.msg
        return defaultResponse()

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
    maxRequestBodySize: int = 1_048_576) =
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
  info "Starting JSON-RPC HTTP server", url = "http://" & $address

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
    maxRequestBodySize: int = 1_048_576) =
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

  info "Starting JSON-RPC HTTPS server", url = "https://" & $address

  rpcServer.httpServers.add server

proc addHttpServers*(server: RpcHttpServer,
                       addresses: openArray[TransportAddress]) =
  for item in addresses:
    # TODO handle partial failures, ie when 1/N addresses fail
    server.addHttpServer(item)

proc addSecureHttpServers*(server: RpcHttpServer,
                           addresses: openArray[TransportAddress],
                           tlsPrivateKey: TLSPrivateKey,
                           tlsCertificate: TLSCertificate) =
  for item in addresses:
    # TODO handle partial failures, ie when 1/N addresses fail
    server.addSecureHttpServer(item, tlsPrivateKey, tlsCertificate)

template processResolvedAddresses =
  if tas4.len + tas6.len == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to get address!")

  for r in tas4:
    yield r

  if tas4.len == 0: # avoid ipv4 + ipv6 running together
    for r in tas6:
      yield r

iterator resolvedAddresses(address: string): TransportAddress =
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, AddressFamily.IPv4)
  except CatchableError:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, AddressFamily.IPv6)
  except CatchableError:
    discard

  processResolvedAddresses()

iterator resolvedAddresses(address: string, port: Port): TransportAddress =
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, port, AddressFamily.IPv4)
  except CatchableError:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, port, AddressFamily.IPv6)
  except CatchableError:
    discard

  processResolvedAddresses()

proc addHttpServer*(server: RpcHttpServer, address: string) =
  ## Create new server and assign it to addresses ``addresses``.
  for a in resolvedAddresses(address):
    # TODO handle partial failures, ie when 1/N addresses fail
    server.addHttpServer(a)

proc addSecureHttpServer*(server: RpcHttpServer,
                          address: string,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate) =
  for a in resolvedAddresses(address):
    # TODO handle partial failures, ie when 1/N addresses fail
    server.addSecureHttpServer(a, tlsPrivateKey, tlsCertificate)

proc addHttpServers*(server: RpcHttpServer, addresses: openArray[string]) =
  for address in addresses:
    # TODO handle partial failures, ie when 1/N addresses fail
    server.addHttpServer(address)

proc addHttpServer*(server: RpcHttpServer, address: string, port: Port) =
  for a in resolvedAddresses(address, port):
    # TODO handle partial failures, ie when 1/N addresses fail
    server.addHttpServer(a)

proc addSecureHttpServer*(server: RpcHttpServer,
                          address: string,
                          port: Port,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate) =
  for a in resolvedAddresses(address, port):
    # TODO handle partial failures, ie when 1/N addresses fail
    server.addSecureHttpServer(a, tlsPrivateKey, tlsCertificate)

proc new*(T: type RpcHttpServer, authHooks: seq[HttpAuthHook] = @[]): T =
  T(router: RpcRouter.init(), httpServers: @[], authHooks: authHooks)

proc new*(T: type RpcHttpServer, router: RpcRouter, authHooks: seq[HttpAuthHook] = @[]): T =
  T(router: router, httpServers: @[], authHooks: authHooks)

proc newRpcHttpServer*(authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  RpcHttpServer.new(authHooks)

proc newRpcHttpServer*(router: RpcRouter, authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  RpcHttpServer.new(router, authHooks)

proc newRpcHttpServer*(addresses: openArray[TransportAddress], authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(authHooks)
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[string], authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(authHooks)
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[string], router: RpcRouter, authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(router, authHooks)
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[TransportAddress], router: RpcRouter, authHooks: seq[HttpAuthHook] = @[]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(router, authHooks)
  result.addHttpServers(addresses)

proc start*(server: RpcHttpServer) =
  ## Start the RPC server.
  for item in server.httpServers:
    # TODO handle partial failures, ie when 1/N addresses fail
    debug "HTTP RPC server started" # (todo: fix this),  address = item
    item.start()

proc stop*(server: RpcHttpServer) {.async.} =
  ## Stop the RPC server.
  for item in server.httpServers:
    debug "HTTP RPC server stopped" # (todo: fix this), address = item.local
    await item.stop()

proc closeWait*(server: RpcHttpServer) {.async.} =
  ## Cleanup resources of RPC server.
  for item in server.httpServers:
    await item.closeWait()
