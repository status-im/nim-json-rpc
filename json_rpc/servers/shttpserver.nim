import
  stew/byteutils,
  std/[strutils],
  chronicles, httputils, chronos,
  chronos/apps/http/shttpserver,
  ".."/[errors, server]

export server

logScope:
  topics = "JSONRPC-HTTPS-SERVER"

type
  ReqStatus = enum
    Success, Error, ErrorFailure

  RpcSecureHttpServer* = ref object of RpcServer
    secureHttpServers: seq[SecureHttpServerRef]

proc addSecureHttpServer*(rpcServer: RpcSecureHttpServer,
                          address: TransportAddress,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate
                         ) =
  proc processClientRpc(rpcServer: RpcSecureHttpServer): HttpProcessCallback {.closure.} =
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
          let res = await request.respond(Http200, data)
          trace "JSON-RPC result has been sent"
          return res
      else:
        if req.error.code == Http408:
          debug "Timeout error while processing JSON-RPC call"     
        return dumbResponse()

  let initialServerCount = len(rpcServer.secureHttpServers)
  try:
    info "Starting JSON-RPC HTTPS server", url = "https://" & $address
    var res = SecureHttpServerRef.new(address,
                                      processClientRpc(rpcServer),
                                      tlsPrivateKey,
                                      tlsCertificate,
                                      serverFlags = {Secure},
                                      socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
                                     )
    if res.isOk():
      let secureHttpServer = res.get()
      rpcServer.secureHttpServers.add(secureHttpServer)
    else:
      raise newException(RpcBindError, "Unable to create server!")

  except CatchableError as exc:
    error "Failed to create server", address = $address,
                                     message = exc.msg

  if len(rpcServer.secureHttpServers) != initialServerCount + 1:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc addSecureHttpServers*(server: RpcSecureHttpServer,
                           addresses: openArray[TransportAddress],
                           tlsPrivateKey: TLSPrivateKey,
                           tlsCertificate: TLSCertificate
                          ) =
  for item in addresses:
    server.addSecureHttpServer(item, tlsPrivateKey, tlsCertificate)

proc addSecureHttpServer*(server: RpcSecureHttpServer,
                          address: string,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate
                         ) =
  ## Create new server and assign it to addresses ``addresses``.
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

  for r in tas4:
    server.addSecureHttpServer(r, tlsPrivateKey, tlsCertificate)
    added.inc
  if added == 0: # avoid ipv4 + ipv6 running together
    for r in tas6:
      server.addSecureHttpServer(r, tlsPrivateKey, tlsCertificate)
      added.inc

  if added == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to get address!")

proc addSecureHttpServers*(server: RpcSecureHttpServer,
                     addresses: openArray[string],
                     tlsPrivateKey: TLSPrivateKey,
                     tlsCertificate: TLSCertificate
                    ) =
  for address in addresses:
    server.addSecureHttpServer(address, tlsPrivateKey, tlsCertificate)

proc addSecureHttpServer*(server: RpcSecureHttpServer,
                          address: string,
                          port: Port,
                          tlsPrivateKey: TLSPrivateKey,
                          tlsCertificate: TLSCertificate
                         ) =
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

  if len(tas4) == 0 and len(tas6) == 0:
    # Address was not resolved, critical error.
    raise newException(RpcAddressUnresolvableError,
                       "Address " & address & " could not be resolved!")

  for r in tas4:
    server.addSecureHttpServer(r, tlsPrivateKey, tlsCertificate)
    added.inc
  for r in tas6:
    server.addSecureHttpServer(r, tlsPrivateKey, tlsCertificate)
    added.inc

  if len(server.secureHttpServers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError,
                      "Could not setup server on " & address & ":" & $int(port))

proc new*(T: type RpcSecureHttpServer): T =
  T(router: RpcRouter.init(), secureHttpServers: @[])

proc newRpcSecureHttpServer*(): RpcSecureHttpServer =
  RpcSecureHttpServer.new()

proc newRpcSecureHttpServer*(addresses: openArray[TransportAddress],
                             tlsPrivateKey: TLSPrivateKey,
                             tlsCertificate: TLSCertificate
                            ): RpcSecureHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcSecureHttpServer()
  result.addSecureHttpServers(addresses, tlsPrivateKey, tlsCertificate)

proc newRpcSecureHttpServer*(addresses: openArray[string],
                             tlsPrivateKey: TLSPrivateKey,
                             tlsCertificate: TLSCertificate
                            ): RpcSecureHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcSecureHttpServer()
  result.addSecureHttpServers(addresses, tlsPrivateKey, tlsCertificate)

proc start*(server: RpcSecureHttpServer) =
  ## Start the RPC server.
  for item in server.secureHttpServers:
    debug "HTTPS RPC server started" # (todo: fix this),  address = item
    item.start()

proc stop*(server: RpcSecureHttpServer) {.async.} =
  ## Stop the RPC server.
  for item in server.secureHttpServers:
    debug "HTTPS RPC server stopped" # (todo: fix this), address = item.local
    await item.stop()

proc closeWait*(server: RpcSecureHttpServer) {.async.} =
  ## Cleanup resources of RPC server.
  for item in server.secureHttpServers:
    await item.closeWait()