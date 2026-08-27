# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## A JSON-RPC server that serves a single connection over standard
## input/output - the transport an LSP or MCP server is launched with.
##
## Like `RpcSocketServer`, this is the transport's bidirectional connection -
## an `RpcStdioClient` - with the server's router plugged in: incoming requests
## are routed, and the connection is registered in `connections` so
## `server.notify(...)` reaches the peer. There is no accept loop, because a
## process has exactly one standard input.
##
## Anything written to stdout other than protocol messages will corrupt the
## stream, so send logs to stderr or a file.

{.push raises: [], gcsafe.}

import
  chronicles,
  chronos,
  ../[errors, server],
  ../private/jrpc_sys,
  ../clients/stdioclient

export errors, server, StdioFraming, lengthHeaderBE32, httpHeader, newLine

logScope:
  topics = "jsonrpc server stdio"

type RpcStdioServer* = ref object of RpcServer
  connection: RpcStdioClient
  loop: Future[void].Raising([])
  maxMessageSize: int
  framing: StdioFraming

proc new*(
    T: type RpcStdioServer,
    maxMessageSize = defaultMaxMessageSize,
    framing = StdioFraming.httpHeader(),
): T =
  T(
    router: RpcRouter.init(),
    maxMessageSize: maxMessageSize,
    framing: framing,
  )

proc newRpcStdioServer*(
    maxMessageSize = defaultMaxMessageSize, framing = StdioFraming.httpHeader()
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

proc serve*(server: RpcStdioServer) {.async: (raises: []).} =
  if server.connection == nil:
    try:
      server.start()
    except JsonRpcError as exc:
      error "Unable to serve standard input/output", err = exc.msg
      return

  await server.loop
  server.connections.excl(server.connection)
  server.connection = nil

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
