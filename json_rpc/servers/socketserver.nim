import
  std/json,
  chronicles,
  json_serialization/std/net,
  ../server, ../errors

export server

type
  RpcSocketServer* = ref object of RpcServer
    servers: seq[StreamServer]

proc sendError*[T](transport: T, code: int, msg: string, id: JsonNode,
                data: JsonNode = newJNull()) {.async.} =
  ## Send error message to client
  let error = wrapError(code, msg, id, data)
  result = transport.write(string wrapReply(id, StringOfJson("null"), error))

proc processClient(server: StreamServer, transport: StreamTransport) {.async, gcsafe.} =
  ## Process transport data to the RPC server
  var rpc = getUserData[RpcSocketServer](server)
  while true:
    var
      value = await transport.readLine(defaultMaxRequestLength)
    if value == "":
      await transport.closeWait()
      break

    debug "Processing message", address = transport.remoteAddress(), line = value

    let res = await rpc.route(value)
    discard await transport.write(res)

# Utility functions for setting up servers using stream transport addresses

proc addStreamServer*(server: RpcSocketServer, address: TransportAddress) =
  try:
    info "Starting JSON-RPC socket server", address = $address
    var transportServer = createStreamServer(address, processClient, {ReuseAddr}, udata = server)
    server.servers.add(transportServer)
  except CatchableError as exc:
    error "Failed to create server", address = $address, message = exc.msg

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc addStreamServers*(server: RpcSocketServer, addresses: openarray[TransportAddress]) =
  for item in addresses:
    server.addStreamServer(item)

proc addStreamServer*(server: RpcSocketServer, address: string) =
  ## Create new server and assign it to addresses ``addresses``.
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    added = 0

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, AddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, AddressFamily.IPv6)
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

proc addStreamServers*(server: RpcSocketServer, addresses: openarray[string]) =
  for address in addresses:
    server.addStreamServer(address)

proc addStreamServer*(server: RpcSocketServer, address: string, port: Port) =
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    added = 0

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, port, AddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, port, AddressFamily.IPv6)
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

proc newRpcSocketServer*: RpcSocketServer =
  RpcSocketServer(router: newRpcRouter(), servers: @[])

proc newRpcSocketServer*(addresses: openarray[TransportAddress]): RpcSocketServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcSocketServer()
  result.addStreamServers(addresses)

proc newRpcSocketServer*(addresses: openarray[string]): RpcSocketServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcSocketServer()
  result.addStreamServers(addresses)

proc newRpcSocketServer*(address: string, port: Port = Port(8545)): RpcSocketServer =
  # Create server on specified port
  result = newRpcSocketServer()
  result.addStreamServer(address, port)

proc start*(server: RpcSocketServer) =
  ## Start the RPC server.
  for item in server.servers:
    item.start()

proc stop*(server: RpcSocketServer) =
  ## Stop the RPC server.
  for item in server.servers:
    item.stop()

proc close*(server: RpcSocketServer) =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    item.close()

proc closeWait*(server: RpcSocketServer) {.async.} =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    await item.closeWait()
