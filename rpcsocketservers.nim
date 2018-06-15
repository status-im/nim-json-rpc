import rpcserver, tables, asyncdispatch2
export rpcserver

# Temporarily disable logging
import macros
macro debug(body: varargs[untyped]): untyped = newStmtList()
macro info(body: varargs[untyped]): untyped = newStmtList()
macro error(body: varargs[untyped]): untyped = newStmtList()

type RpcStreamServer* = RpcServer[StreamServer]

proc newRpcSocketServer*(addresses: openarray[TransportAddress]): RpcStreamServer = 
  ## Create new server and assign it to addresses ``addresses``.
  result = RpcServer[StreamServer]()
  result.procs = newTable[string, RpcProc]()
  result.servers = newSeq[StreamServer]()

  for item in addresses:
    try:
      info "Creating server on ", address = $item
      var server = createStreamServer(item, processClient, {ReuseAddr},
                                      udata = result)
      result.servers.add(server)
    except:
      error "Failed to create server", address = $item, message = getCurrentExceptionMsg()

  if len(result.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc newRpcSocketServer*(addresses: openarray[string]): RpcServer[StreamServer] =
  ## Create new server and assign it to addresses ``addresses``.  
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    baddrs: seq[TransportAddress]

  for a in addresses:
    # Attempt to resolve `address` for IPv4 address space.
    try:
      tas4 = resolveTAddress(a, IpAddressFamily.IPv4)
    except:
      discard

    # Attempt to resolve `address` for IPv6 address space.
    try:
      tas6 = resolveTAddress(a, IpAddressFamily.IPv6)
    except:
      discard

    for r in tas4:
      baddrs.add(r)
    for r in tas6:
      baddrs.add(r)

  if len(baddrs) == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to get address!")

  result = newRpcSocketServer(baddrs)

proc newRpcSocketServer*(address = "localhost", port: Port = Port(8545)): RpcServer[StreamServer] =
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, port, IpAddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, port, IpAddressFamily.IPv6)
  except:
    error "Failed to create server for address", address = $item, errror = getCurrentException()

  if len(tas4) == 0 and len(tas6) == 0:
    # Address was not resolved, critical error.
    raise newException(RpcAddressUnresolvableError,
                       "Address " & address & " could not be resolved!")

  result = RpcServer[StreamServer]()
  result.procs = newTable[string, RpcProc]()
  result.servers = newSeq[StreamServer]()
  for item in tas4:
    try:
      info "Creating server for address", ip4address = $item
      var server = createStreamServer(item, processClient, {ReuseAddr},
                                      udata = result)
      result.servers.add(server)
    except:
      error "Failed to create server for address", address = $item, errror = getCurrentException()

  for item in tas6:
    try:
      info "Server created", ip6address = $item
      var server = createStreamServer(item, processClient, {ReuseAddr},
                                      udata = result)
      result.servers.add(server)
    except:
      error "Failed to create server for address", address = $item, errror = getCurrentException()

  if len(result.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError,
                      "Could not setup server on " & address & ":" & $int(port))

