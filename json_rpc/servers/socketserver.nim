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
  chronicles,
  json_serialization/std/net as jsnet,
  ../private/utils,
  ../errors,
  ../server

export errors, server, jsnet

type
  RpcSocketServer* = ref object of RpcServer
    servers: seq[StreamServer]
    processClientHook: StreamCallback2

# TODO replace with configurable value
const defaultMaxRequestLength* = 1024 * 128

proc processClient(server: StreamServer, transport: StreamTransport) {.async: (raises: []).} =
  ## Process transport data to the RPC server
  try:
    var rpc = getUserData[RpcSocketServer](server)
    while true:
      let req = await transport.readLine(defaultMaxRequestLength)
      if req == "":
        debugEcho "closing, ", transport.atEof()
        break

      debug "Received JSON-RPC request",
        address = transport.remoteAddress(),
        len = req.len

      let res = await rpc.route(req)
      discard await transport.write(res & "\r\n")
  except TransportError as ex:
    error "Transport closed during processing client",
      address = transport.remoteAddress(),
      msg=ex.msg
  except CancelledError:
    error "JSON-RPC request processing cancelled",
      address = transport.remoteAddress()
  finally:
    await transport.closeWait()

# Utility functions for setting up servers using stream transport addresses

proc addStreamServer*(server: RpcSocketServer, address: TransportAddress) {.raises: [JsonRpcError].} =
  try:
    var transportServer = createStreamServer(address, server.processClientHook, {ReuseAddr}, udata = server)
    server.servers.add(transportServer)
  except CatchableError as exc:
    error "Failed to create server", address = $address, message = exc.msg
    raise newException(RpcBindError, "Unable to create stream server: " & exc.msg)

proc addStreamServers*(server: RpcSocketServer, addresses: openArray[TransportAddress]) {.raises: [JsonRpcError].} =
  var lastExc: ref JsonRpcError
  for item in addresses:
    try:
      server.addStreamServer(item)
    except JsonRpcError as exc:
      lastExc = exc
  if server.servers.len == 0:
    raise lastExc

proc addStreamServer*(server: RpcSocketServer, address: string) {.raises: [JsonRpcError].} =
  ## Create new server and assign it to addresses ``addresses``.
  addStreamServers(server, toSeq(resolveIP([address])))

proc addStreamServers*(server: RpcSocketServer, addresses: openArray[string]) {.raises: [JsonRpcError].} =
  addStreamServers(server, toSeq(resolveIP(addresses)))

proc addStreamServer*(server: RpcSocketServer, address: string, port: Port) {.raises: [JsonRpcError].} =
  addStreamServers(server, toSeq(resolveIP(address, port)))

proc new(T: type RpcSocketServer): T =
  T(router: RpcRouter.init(), servers: @[], processClientHook: processClient)

proc newRpcSocketServer*(): RpcSocketServer =
  RpcSocketServer.new()

proc newRpcSocketServer*(addresses: openArray[TransportAddress]): RpcSocketServer {.raises: [JsonRpcError].} =
  ## Create new server and assign it to addresses ``addresses``.
  result = RpcSocketServer.new()
  result.addStreamServers(addresses)

proc newRpcSocketServer*(addresses: openArray[string]): RpcSocketServer {.raises: [JsonRpcError].} =
  ## Create new server and assign it to addresses ``addresses``.
  result = RpcSocketServer.new()
  result.addStreamServers(addresses)

proc newRpcSocketServer*(address: string, port: Port = Port(8545)): RpcSocketServer {.raises: [JsonRpcError].} =
  # Create server on specified port
  result = RpcSocketServer.new()
  result.addStreamServer(address, port)

proc newRpcSocketServer*(processClientHook: StreamCallback2): RpcSocketServer =
  ## Create new server with custom processClientHook.
  result = RpcSocketServer.new()
  result.processClientHook = processClientHook

proc start*(server: RpcSocketServer) {.raises: [JsonRpcError].} =
  ## Start the RPC server.
  for item in server.servers:
    try:
      info "Starting JSON-RPC socket server", address = item.localAddress
      item.start()
    except TransportOsError as exc:
      # TODO stop already-started servers
      raise (ref RpcBindError)(msg: exc.msg, parent: exc)

proc stop*(server: RpcSocketServer) =
  ## Stop the RPC server.
  for item in server.servers:
    try:
      item.stop()
    except TransportOsError as exc:
      warn "Could not stop transport", err = exc.msg

proc close*(server: RpcSocketServer) =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    item.close()

proc closeWait*(server: RpcSocketServer) {.async: (raises: []).} =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    await item.closeWait()

proc localAddress*(server: RpcSocketServer): seq[TransportAddress] =
  for x in server.servers:
    result.add x.localAddress
