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
  chronos,
  json_serialization/std/net as jsnet,
  ../private/utils,
  ../[errors, server],
  ../private/jrpc_sys,
  ../clients/socketclient

export errors, server, jsnet

logScope:
  topics = "jsonrpc server socket"

type
  RpcSocketServer* = ref object of RpcServer
    servers: seq[StreamServer]
    processClientHook: StreamCallback2
    maxMessageSize: int

proc processClient(
    server: StreamServer, transport: StreamTransport
) {.async: (raises: []).} =
  ## Process transport data to the RPC server

  let
    rpc = getUserData[RpcSocketServer](server)
    remote = transport.remoteAddress2().valueOr(default(TransportAddress))
    c = RpcSocketClient(
      transport: transport,
      address: remote,
      remote: $remote,
      maxMessageSize: rpc.maxMessageSize,
      router: proc(
          request: RequestBatchRx
      ): Future[string] {.async: (raises: [], raw: true).} =
        rpc.router.route(request),
    )

  rpc.connections.incl(c)

  await c.processMessages()

  rpc.connections.excl(c)

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

proc new(T: type RpcSocketServer, maxMessageSize = defaultMaxMessageSize): T =
  T(
    router: RpcRouter.init(),
    servers: @[],
    maxMessageSize: maxMessageSize,
    processClientHook: processClient,
  )

proc newRpcSocketServer*(maxMessageSize = defaultMaxMessageSize): RpcSocketServer =
  RpcSocketServer.new(maxMessageSize)

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
