import
  std/[strutils],
  chronicles, httputils, chronos,
  chronos/apps/http/httpserver,
  ".."/[errors, server]

export server

logScope:
  topics = "JSONRPC-HTTP-SERVER"

type
  ReqStatus = enum
    Success, Error, ErrorFailure

  RpcHttpServer* = ref object of RpcServer
    httpServers: seq[HttpServerRef]

proc addHttpServer*(rpcServer: RpcHttpServer, address: TransportAddress) =
  proc processClientRpc(rpcServer: RpcHttpServer): HttpProcessCallback {.closure.} =
    return proc (req: RequestFence): Future[HttpResponseRef] {.async.} =
      if req.isOk():
        let request = req.get()
        let body = await request.getBody()

        let future = rpcServer.route(cast[string](body))
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
        return dumbResponse()

  let initialServerCount = len(rpcServer.httpServers)
  try:
    info "Starting JSON-RPC HTTP server", url = "http://" & $address
    var res = HttpServerRef.new(address, processClientRpc(rpcServer))
    if res.isOk():
      let httpServer = res.get()
      rpcServer.httpServers.add(httpServer)
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

proc addHttpServer*(server: RpcHttpServer, address: string) =
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
    server.addHttpServer(r)
    added.inc
  if added == 0: # avoid ipv4 + ipv6 running together
    for r in tas6:
      server.addHttpServer(r)
      added.inc

  if added == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to get address!")

proc addHttpServers*(server: RpcHttpServer, addresses: openArray[string]) =
  for address in addresses:
    server.addHttpServer(address)

proc addHttpServer*(server: RpcHttpServer, address: string, port: Port) =
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
    server.addHttpServer(r)
    added.inc
  for r in tas6:
    server.addHttpServer(r)
    added.inc

  if len(server.httpServers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError,
                      "Could not setup server on " & address & ":" & $int(port))

proc new*(T: type RpcHttpServer): T =
  T(router: RpcRouter.init(), httpServers: @[])

proc newRpcHttpServer*(): RpcHttpServer =
  RpcHttpServer.new()

proc newRpcHttpServer*(addresses: openArray[TransportAddress]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer()
  result.addHttpServers(addresses)

proc newRpcHttpServer*(addresses: openArray[string]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer()
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
