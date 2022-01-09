import
  stew/byteutils,
  chronicles, httputils, chronos,
  chronos/apps/http/[httpserver, shttpserver],
  ".."/[errors, server]

export server

logScope:
  topics = "JSONRPC-HTTP-SERVER"

type
  ReqStatus = enum
    Success, Error, ErrorFailure

  RpcHttpServer* = ref object of RpcServer
    httpServers: seq[HttpServerRef]

proc processClientRpc(rpcServer: RpcServer): HttpProcessCallback =
  return proc (req: RequestFence): Future[HttpResponseRef] {.async.} =
    if req.isOk():
      let request = req.get()
      let body = await request.getBody()

      let future = rpcServer.route(string.fromBytes(body))
      yield future
      if future.failed:
        debug "Internal error while processing JSON-RPC call"
        return await request.respond(Http503, "Internal error while processing JSON-RPC call")
      else:
        var data = future.read()
        if data.isSome:
          let res = await request.respond(Http200, string(data.get))
          trace "JSON-RPC result has been sent"
          return res
        else:
          let res = await request.respond(Http204)
          trace "No-content has been sent"
          return res
    else:
      return dumbResponse()

proc addHttpServer*(rpcServer: RpcHttpServer, address: TransportAddress) =
  let initialServerCount = len(rpcServer.httpServers)
  try:
    info "Starting JSON-RPC HTTP server", url = "http://" & $address
    var res = HttpServerRef.new(address, processClientRpc(rpcServer))
    if res.isOk():
      rpcServer.httpServers.add(res.get())
    else:
      raise newException(RpcBindError, "Unable to create server!")

  except CatchableError as exc:
    error "Failed to create server", address = $address,
                                     message = exc.msg

  if len(rpcServer.httpServers) != initialServerCount + 1:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc addSecureHttpServer*(rpcServer: RpcHttpServer,
                          address: TransportAddress,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate) =
  let initialServerCount = len(rpcServer.httpServers)
  try:
    info "Starting JSON-RPC HTTPS server", url = "https://" & $address
    var res = SecureHttpServerRef.new(address,
                                      processClientRpc(rpcServer),
                                      tlsPrivateKey,
                                      tlsCertificate,
                                      serverFlags = {HttpServerFlags.Secure},
                                      socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr})
    if res.isOk():
      rpcServer.httpServers.add(res.get())
    else:
      raise newException(RpcBindError, "Unable to create server!")

  except CatchableError as exc:
    error "Failed to create server", address = $address,
                                     message = exc.msg

  if len(rpcServer.httpServers) != initialServerCount + 1:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc addHttpServers*(server: RpcHttpServer,
                       addresses: openArray[TransportAddress]) =
  for item in addresses:
    server.addHttpServer(item)

proc addSecureHttpServers*(server: RpcHttpServer,
                           addresses: openArray[TransportAddress],
                           tlsPrivateKey: TLSPrivateKey,
                           tlsCertificate: TLSCertificate) =
  for item in addresses:
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
    added = 0

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
    added = 0

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
    server.addHttpServer(a)

proc addSecureHttpServer*(server: RpcHttpServer,
                          address: string,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate) =
  for a in resolvedAddresses(address):
    server.addSecureHttpServer(a, tlsPrivateKey, tlsCertificate)

proc addHttpServers*(server: RpcHttpServer, addresses: openArray[string]) =
  for address in addresses:
    server.addHttpServer(address)

proc addHttpServer*(server: RpcHttpServer, address: string, port: Port) =
  for a in resolvedAddresses(address, port):
    server.addHttpServer(a)

  if len(server.httpServers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError,
                      "Could not setup server on " & address & ":" & $int(port))

proc addSecureHttpServer*(server: RpcHttpServer,
                          address: string,
                          port: Port,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate) =
  for a in resolvedAddresses(address, port):
    server.addSecureHttpServer(a, tlsPrivateKey, tlsCertificate)

proc new*(T: type RpcHttpServer): T =
  T(router: RpcRouter.init(), httpServers: @[])

proc new*(T: type RpcHttpServer, router: RpcRouter): T =
  T(router: router, httpServers: @[])

proc newRpcHttpServer*(): RpcHttpServer =
  RpcHttpServer.new()

proc newRpcHttpServer*(router: RpcRouter): RpcHttpServer =
  RpcHttpServer.new(router)

proc newRpcHttpServer*(addresses: openArray[TransportAddress]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer()
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[string]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer()
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[string], router: RpcRouter): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(router)
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[TransportAddress], router: RpcRouter): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer(router)
  result.addHttpServers(addresses)

proc start*(server: RpcHttpServer) =
  ## Start the RPC server.
  for item in server.httpServers:
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
