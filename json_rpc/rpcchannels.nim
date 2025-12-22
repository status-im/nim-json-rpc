## This module provides a lightweight, thread‑safe JSON‑RPC channel that can be
## used to connect a client and a server running in different threads, reusing
## existing JSON-RPC infrastructure already present in the application.

{.push raises: [], gcsafe.}

when (NimMajor, NimMinor, NimPatch) < (2, 2, 4):
  {.error: "RPC channels are only available with Nim 2.2.4+".}

import ./[client, errors, router, server], asyncchannels, ./private/jrpc_sys
export client, errors, server

type
  RpcChannel* = object
    ## An RPC channel represents a thread‑safe, bidirectional communications
    ## channel from which a single "server" and a single "client" can be formed.
    ##
    ## The channel can be allocated in any thread while the server and client
    ## instances should be created in the thread where they will be used,
    ## passing to them the `RpcChannelPtrs` instance returned from `open`.
    recv, send: AsyncChannel[seq[byte]]

  RpcChannelPtrs* = object ## Raw pointer pair that can be moved to another thread.
    recv, send: ptr AsyncChannel[seq[byte]]
      # The `recv` pointer is the channel that receives data, the `send` pointer
      # is the channel that sends data.  The two pointers are swapped when
      # the channel is handed to the opposite side.

  RpcChannelClient* = ref object of RpcConnection
    channel: RpcChannelPtrs
    loop: Future[void]

  RpcChannelServer* = ref object of RpcServer
    client: RpcChannelClient

proc open*(c: var RpcChannel): Result[RpcChannelPtrs, string] =
  ## Open the channel, returning a channel pair that can be passed to the
  ## server and client threads respectively.
  ##
  ## Only one server and client instance each may use the returned channel
  ## pairs. The returned `RpcChannelPtrs` are raw pointers that must be
  ## moved to the thread that will own the client or server.
  ?c.recv.open()

  c.send.open().isOkOr:
    c.recv.close()
    return err(error)

  ok (RpcChannelPtrs(recv: addr c.recv, send: addr c.send))

proc close*(c: var RpcChannel) =
  c.recv.close()
  c.recv.reset()
  c.send.close()
  c.send.reset()

proc new*(
    T: type RpcChannelClient, channel: RpcChannelPtrs, router = default(ref RpcRouter)
): T =
  ## Create a new `RpcChannelClient` that will use the supplied `channel`.
  ## If a `router` is supplied, it will be used to route incoming requests.
  ## The returned client is ready to be connected with `connect`.
  let router =
    if router != nil:
      proc(
          request: RequestBatchRx
      ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
        router[].route(request)
    else:
      nil

  T(channel: channel, router: router, remote: "client")

proc newRpcChannelClient*(
    channel: RpcChannelPtrs, router = default(ref RpcRouter)
): RpcChannelClient =
  ## Convenience wrapper that creates a new `RpcChannelClient` from a
  ## `RpcChannelPtrs` pair.  The client can be used immediately or after
  ## calling `connect`.
  RpcChannelClient.new(channel, router)

method send*(
    client: RpcChannelClient, reqData: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Send a raw JSON‑RPC request to the remote side.
  ## The data is written synchronously to the underlying channel.
  client.channel.send[].sendSync(reqData)

method request*(
    client: RpcChannelClient, reqData: seq[byte]
): Future[seq[byte]] {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Send a request and wait for the corresponding response.
  ## The request is sent synchronously and the future returned by
  ## `client.processMessage` is awaited.
  client.withPendingFut(fut):
    client.channel.send[].sendSync(reqData)

    await fut

proc processData(client: RpcChannelClient) {.async: (raises: []).} =
  ## Internal loop that receives data from the channel, processes it
  ## with `client.processMessage`, and sends back any response.
  ## The loop terminates when the channel is closed or a
  ## `CancelledError` is raised.
  var lastError: ref JsonRpcError
  try:
    while true:
      let
        data = await client.channel.recv.recv()
        resp = await client.processMessage(data)

      if resp.len > 0:
        client.channel.send[].sendSync(resp)
  except CancelledError:
    discard # shutting down

  if lastError == nil:
    lastError = (ref RpcTransportError)(msg: "Connection closed")

  client.clearPending(lastError)

  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc connect*(
    client: RpcChannelClient
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Start the client's background processing loop.
  ## After calling this, the client is ready to send requests.
  doAssert client.loop == nil, "Must not already be connected"
  client.loop = client.processData()

method close*(client: RpcChannelClient) {.async: (raises: []).} =
  ## Gracefully shut down the client.
  ## Cancels the background loop and waits for it to finish.
  if client.loop != nil:
    let loop = move(client.loop)
    await loop.cancelAndWait()

proc new*(T: type RpcChannelServer, channel: RpcChannelPtrs): T =
  ## Create a new `RpcChannelServer` that will listen on the supplied
  ## `channel`.  The server owns a fresh `RpcRouter` instance.
  let
    res = T(router: RpcRouter.init())
    # Compared to the client, swap the channels in the server
    channel = RpcChannelPtrs(recv: channel.send, send: channel.recv)
    router = proc(
        request: RequestBatchRx
    ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
      res[].router.route(request)

    client = RpcChannelClient(channel: channel, router: router, remote: "server")

  res.client = client
  res

proc start*(server: RpcChannelServer) =
  ## Start the RPC server.
  ## The server's background loop is started and the client is ready to
  ## receive requests.

  # `connect` for a thread channel is actually synchronous and cannot fail so
  # we can ignore the future being returned
  discard server.client.connect()
  server.connections.incl server.client

proc stop*(server: RpcChannelServer) =
  discard

proc closeWait*(server: RpcChannelServer) {.async: (raises: []).} =
  ## Gracefully shut down the server.
  server.connections.excl server.client
  await server.client.close()
