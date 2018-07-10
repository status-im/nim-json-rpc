import server, json, chronicles

proc sendError*[T](transport: T, code: int, msg: string, id: JsonNode,
                data: JsonNode = newJNull()) {.async.} =
  ## Send error message to client
  let error = wrapError(code, msg, id, data)
  var value = $wrapReply(id, newJNull(), error)
  result = transport.write(value)

proc processClient(server: StreamServer, transport: StreamTransport) {.async, gcsafe.} =
  ## Process transport data to the RPC server
  var rpc = getUserData[RpcServer[StreamTransport]](server)
  while true:
    var
      maxRequestLength = defaultMaxRequestLength
      value = await transport.readLine(defaultMaxRequestLength)
    if value == "":
      transport.close
      break

    debug "Processing message", address = transport.remoteAddress(), line = value

    let future = rpc.route(value)
    yield future
    if future.failed:
      if future.readError of RpcProcError:
        let err = future.readError.RpcProcError
        await transport.sendError(err.code, err.msg, err.data)
      elif future.readError of ValueError:
        let err = future.readError[].ValueError
        await transport.sendError(INVALID_PARAMS, err.msg, %"")
      else:
        await transport.sendError(SERVER_ERROR,
                              "Error: Unknown error occurred", %"")
    else:
      let res = await future
      result = transport.write(res)

# Utility functions for setting up servers using stream transport addresses

proc addStreamServer*(server: RpcServer[StreamServer], address: TransportAddress) =
  try:
    info "Creating server on ", address = $address
    var transportServer = createStreamServer(address, processClient, {ReuseAddr}, udata = server)
    server.servers.add(transportServer)
  except:
    error "Failed to create server", address = $address, message = getCurrentExceptionMsg()

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc addStreamServers*(server: RpcServer[StreamServer], addresses: openarray[TransportAddress]) =
  for item in addresses:
    server.addStreamServer(item)

proc addStreamServer*(server: RpcServer[StreamServer], address: string) =
  ## Create new server and assign it to addresses ``addresses``.  
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    added = 0

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, IpAddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, IpAddressFamily.IPv6)
  except:
    discard

  for r in tas4:
    server.addStreamServer(r)
    added.inc
  for r in tas6:
    server.addStreamServer(r)
    added.inc

  if added == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to get address!")

proc addStreamServers*(server: RpcServer[StreamServer], addresses: openarray[string]) =
  for address in addresses:
    server.addStreamServer(address)

proc addStreamServer*(server: RpcServer[StreamServer], address: string, port: Port) =
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    added = 0

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, port, IpAddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, port, IpAddressFamily.IPv6)
  except:
    discard

  if len(tas4) == 0 and len(tas6) == 0:
    # Address was not resolved, critical error.
    raise newException(RpcAddressUnresolvableError,
                       "Address " & address & " could not be resolved!")

  for r in tas4:
    server.addStreamServer(r)
    added.inc
  for r in tas6:
    server.addStreamServer(r)
    added.inc

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError,
                      "Could not setup server on " & address & ":" & $int(port))

type RpcStreamServer* = RpcServer[StreamServer]

proc newRpcStreamServer*(addresses: openarray[TransportAddress]): RpcStreamServer = 
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcServer[StreamServer]()
  result.addStreamServers(addresses)

proc newRpcStreamServer*(addresses: openarray[string]): RpcStreamServer =
  ## Create new server and assign it to addresses ``addresses``.  
  result = newRpcServer[StreamServer]()
  result.addStreamServers(addresses)

proc newRpcStreamServer*(address = "localhost", port: Port = Port(8545)): RpcStreamServer =
  # Create server on specified port
  result = newRpcServer[StreamServer]()
  result.addStreamServer(address, port)

proc start*(server: RpcStreamServer) =
  ## Start the RPC server.
  for item in server.servers:
    item.start()

proc stop*(server: RpcStreamServer) =
  ## Stop the RPC server.
  for item in server.servers:
    item.stop()

proc close*(server: RpcStreamServer) =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    item.close()