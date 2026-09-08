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

type
  RpcStdioServer* = ref object of RpcServer
    connection: RpcStdioClient
    loop: Future[void].Raising([])
    maxMessageSize: int
    framing: Framing
    processClientHook: RpcProcessClient

  RpcProcessClient* = proc(
    server: RpcStdioServer, input, output: StreamTransport
  ): Future[void] {.async: (raises: []), gcsafe.}
    ## Takes over the connection, like the socket server's hook of the same
    ## name - called once with the transports to serve, rather than once per
    ## accepted connection.

proc processClient(
    server: RpcStdioServer, input, output: StreamTransport
) {.async: (raises: []).} =
  ## Serve the connection with the server's own router - the default hook.
  let connection = RpcStdioClient.new(
    maxMessageSize = server.maxMessageSize,
    framing = server.framing,
    router = proc(
        request: RequestBatchRx
    ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
      server.router.route(request),
  )

  server.connection = connection
  server.connections.incl(connection)

  await connection.attach(input, output, "stdio")

proc new*(
    T: type RpcStdioServer,
    maxMessageSize = defaultMaxMessageSize,
    framing = Framing.httpHeader(),
): T =
  T(
    router: RpcRouter.init(),
    maxMessageSize: maxMessageSize,
    framing: framing,
    processClientHook: processClient,
  )

proc newRpcStdioServer*(
    maxMessageSize = defaultMaxMessageSize, framing = Framing.httpHeader()
): RpcStdioServer =
  RpcStdioServer.new(maxMessageSize, framing)

proc newRpcStdioServer*(
    processClientHook: RpcProcessClient,
    maxMessageSize = defaultMaxMessageSize,
    framing = Framing.httpHeader(),
): RpcStdioServer =
  ## Create new server with custom processClientHook.
  result = RpcStdioServer.new(maxMessageSize, framing)
  result.processClientHook = processClientHook

proc start*(
    server: RpcStdioServer, input, output: StreamTransport
) {.raises: [JsonRpcError].} =
  if server.loop != nil:
    raise (ref RpcBindError)(msg: "The server is already serving a connection")

  server.loop = server.processClientHook(server, input, output)

proc start*(server: RpcStdioServer) {.raises: [JsonRpcError].} =
  let (input, output) = stdioTransports()
  info "Starting JSON-RPC stdio server"
  server.start(input, output)

proc serve*(
    server: RpcStdioServer
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if server.loop == nil:
    server.start()

  await server.loop
  server.loop = nil

  # A custom hook owns its connection, and leaves this one nil
  let connection = server.connection
  if connection == nil:
    return

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
