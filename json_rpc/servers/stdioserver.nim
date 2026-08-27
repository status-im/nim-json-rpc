# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  chronicles,
  chronos,
  ../[errors, server],
  ../private/jrpc_sys,
  ../clients/shared/framing,
  ../clients/stdioclient

export errors, server, framing

logScope:
  topics = "jsonrpc server stdio"

type RpcStdioServer* = ref object of RpcServer
  connection: RpcStdioClient
  loop: Future[void].Raising([])
  maxMessageSize: int
  framing: Framing

proc new*(
    T: type RpcStdioServer,
    maxMessageSize = defaultMaxMessageSize,
    framing = Framing.httpHeader(),
): T =
  T(
    router: RpcRouter.init(),
    maxMessageSize: maxMessageSize,
    framing: framing,
  )

proc newRpcStdioServer*(
    maxMessageSize = defaultMaxMessageSize, framing = Framing.httpHeader()
): RpcStdioServer =
  RpcStdioServer.new(maxMessageSize, framing)

proc start*(server: RpcStdioServer) {.raises: [JsonRpcError].} =
  if server.connection != nil:
    raise (ref RpcBindError)(msg: "Standard input/output is already being served")

  let
    (input, output) = stdioTransports()
    connection = RpcStdioClient.new(
      maxMessageSize = server.maxMessageSize,
      framing = server.framing,
      router = proc(
          request: RequestBatchRx
      ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
        server.router.route(request),
    )

  info "Starting JSON-RPC stdio server"
  server.connection = connection
  server.connections.incl(connection)
  server.loop = connection.attach(input, output, "stdio")

proc serve*(
    server: RpcStdioServer
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if server.connection == nil:
    server.start()

  await server.loop

  let connection = server.connection
  server.connections.excl(connection)
  server.connection = nil

  let failure = connection.failure
  if failure != nil:
    raise failure

proc stop*(server: RpcStdioServer) {.async: (raises: []).} =
  if server.loop != nil:
    let loop = move(server.loop)
    await loop.cancelAndWait()
  if server.connection != nil:
    server.connections.excl(server.connection)
    server.connection = nil

proc closeWait*(server: RpcStdioServer) {.async: (raises: []).} =
  await server.stop()

proc connection*(server: RpcStdioServer): RpcConnection =
  server.connection

{.pop.}
