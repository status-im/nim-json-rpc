# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronicles,
  json_serialization/std/net,
  ../errors,
  ../server

export errors, server

type
  RpcSocketServer* = ref object of RpcServer
    servers: seq[StreamServer]
    processClientHook: StreamCallback2

proc processClient(server: StreamServer, transport: StreamTransport) {.async: (raises: []), gcsafe.} =
  ## Process transport data to the RPC server
  try:
    var rpc = getUserData[RpcSocketServer](server)
    while true:
      var
        value = await transport.readLine(defaultMaxRequestLength)
      if value == "":
        await transport.closeWait()
        break

      debug "Processing message", address = transport.remoteAddress(), line = value

      let res = await rpc.route(value)
      discard await transport.write(res & "\r\n")
  except TransportError as ex:
    error "Transport closed during processing client", msg=ex.msg
  except CatchableError as ex:
    error "Error occured during processing client", msg=ex.msg

# Utility functions for setting up servers using stream transport addresses

proc addStreamServer*(server: RpcSocketServer, address: TransportAddress) =
  try:
    info "Starting JSON-RPC socket server", address = $address
    var transportServer = createStreamServer(address, server.processClientHook, {ReuseAddr}, udata = server)
    server.servers.add(transportServer)
  except CatchableError as exc:
    error "Failed to create server", address = $address, message = exc.msg

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc addStreamServers*(server: RpcSocketServer, addresses: openArray[TransportAddress]) =
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
  except CatchableError:
    discard
  except Defect:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, AddressFamily.IPv6)
  except CatchableError:
    discard
  except Defect:
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

proc addStreamServers*(server: RpcSocketServer, addresses: openArray[string]) =
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
  except CatchableError:
    discard
  except Defect:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, port, AddressFamily.IPv6)
  except CatchableError:
    discard
  except Defect:
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

proc new(T: type RpcSocketServer): T =
  T(router: RpcRouter.init(), servers: @[], processClientHook: processClient)

proc newRpcSocketServer*(): RpcSocketServer =
  RpcSocketServer.new()

proc newRpcSocketServer*(addresses: openArray[TransportAddress]): RpcSocketServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = RpcSocketServer.new()
  result.addStreamServers(addresses)

proc newRpcSocketServer*(addresses: openArray[string]): RpcSocketServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = RpcSocketServer.new()
  result.addStreamServers(addresses)

proc newRpcSocketServer*(address: string, port: Port = Port(8545)): RpcSocketServer =
  # Create server on specified port
  result = RpcSocketServer.new()
  result.addStreamServer(address, port)

proc newRpcSocketServer*(processClientHook: StreamCallback2): RpcSocketServer =
  ## Create new server with custom processClientHook.
  result = RpcSocketServer.new()
  result.processClientHook = processClientHook

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

proc localAddress*(server: RpcSocketServer): seq[TransportAddress] =
  for x in server.servers:
    result.add x.localAddress
