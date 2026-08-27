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
  ../clients/pipesclient

export errors, server, framing

logScope:
  topics = "jsonrpc server pipes"

type
  RpcPipesServer* = ref object of RpcServer
    loop*: Future[void].Raising([])
    maxMessageSize*: int
    framing*: Framing
    processClientHook*: RpcProcessClient

  RpcProcessClient* = proc(
    server: RpcPipesServer, input, output: StreamTransport
  ): Future[void] {.async: (raises: []), gcsafe.}

proc processClient*(
    server: RpcPipesServer, input, output: StreamTransport
) {.async: (raises: []).} =
  ## Process transport data to the RPC server
  let connection = RpcPipesClient.new(
    maxMessageSize = server.maxMessageSize,
    framing = server.framing,
    router = proc(
        request: RequestBatchRx
    ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
      server.router.route(request),
  )

  server.connections.incl(connection)

  await connection.attach(input, output, "pipes")

proc new*(
    T: type RpcPipesServer,
    maxMessageSize = defaultMaxMessageSize,
    framing = Framing.httpHeader(),
): T =
  T(
    router: RpcRouter.init(),
    maxMessageSize: maxMessageSize,
    framing: framing,
    processClientHook: processClient,
  )

proc newRpcPipesServer*(
    maxMessageSize = defaultMaxMessageSize, framing = Framing.httpHeader()
): RpcPipesServer =
  RpcPipesServer.new(maxMessageSize, framing)

proc newRpcPipesServer*(
    processClientHook: RpcProcessClient,
    maxMessageSize = defaultMaxMessageSize,
    framing = Framing.httpHeader(),
): RpcPipesServer =
  ## Create new server with custom processClientHook.
  result = RpcPipesServer.new(maxMessageSize, framing)
  result.processClientHook = processClientHook

proc connection*(server: RpcPipesServer): RpcConnection =
  ## The connection being served, nil before `start` and after it ends.
  for connection in server.connections:
    return connection
  nil

proc start*(
    server: RpcPipesServer, input, output: StreamTransport
) {.raises: [JsonRpcError].} =
  if server.loop != nil:
    raise (ref RpcBindError)(msg: "The server is already serving a connection")

  server.loop = server.processClientHook(server, input, output)

proc stop*(server: RpcPipesServer) {.async: (raises: []).} =
  # A handler of a message read while `start` runs the hook can call this
  # before `start` has stored the loop, so the connection is what gets closed
  let connection = server.connection
  let loop = server.loop
  server.loop = nil
  server.connections.clear()
  if connection of RpcPipesClient:
    let connection = RpcPipesClient(connection)
    if connection.output != nil:
      await connection.output.closeWait()
    if connection.input != nil:
      await connection.input.closeWait()
  if loop != nil:
    await loop.cancelAndWait()

proc serve*(
    server: RpcPipesServer
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Serve the connection given to `start` until it ends.
  ## Cancelling it stops the connection, like `stop`.
  if server.loop == nil:
    raise (ref RpcBindError)(msg: "The server is not serving a connection; not started?")

  try:
    await server.loop.join()
  except CancelledError as exc:
    await server.stop()
    raise exc
  server.loop = nil

  let connection = server.connection
  if connection == nil:
    return

  server.connections.excl(connection)

  let failure = connection.lastError
  if failure != nil:
    raise failure

proc closeWait*(server: RpcPipesServer) {.async: (raises: []).} =
  await server.stop()
