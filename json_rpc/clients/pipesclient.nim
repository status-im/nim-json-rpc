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
  ./shared/framing,
  ../[client, errors, router],
  ../private/jrpc_sys

export client, errors, framing

logScope:
  topics = "jsonrpc client pipes"

type
  RpcPipesClient* = ref object of RpcConnection
    ## Bidirectional connection over a pair of pipes
    input*: StreamTransport
    output*: StreamTransport
    loop*: Future[void]
    framing*: Framing

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc new*(
    T: type RpcPipesClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(RpcRouterCallback),
    framing = Framing.httpHeader(),
): T =
  T(maxMessageSize: maxMessageSize, router: router, framing: framing)

proc new*(
    T: type RpcPipesClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
    framing = Framing.httpHeader(),
): T =
  let router =
    if router != nil:
      proc(
          request: RequestBatchRx
      ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
        router[].route(request)
    else:
      nil
  T.new(maxMessageSize, router, framing)

proc newRpcPipesClient*(
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
    framing = Framing.httpHeader(),
): RpcPipesClient =
  ## Creates a new client instance.
  RpcPipesClient.new(maxMessageSize, router, framing)

# ---------------------------------------------------------------------------
# Sending
# ---------------------------------------------------------------------------

method send*(
    client: RpcPipesClient, reqData: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if client.output.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )
  try:
    await client.framing.sendMsg(client.output, reqData)
  except TransportError as exc:
    raise (ref RpcPostError)(msg: exc.msg, parent: exc)

method request(
    client: RpcPipesClient, reqData: seq[byte], id: int
): Future[ResponseBatchRx] {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Remotely calls the specified RPC method.
  if client.output.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )

  client.withPendingFut(fut, id):
    try:
      await client.framing.sendMsg(client.output, reqData)
    except TransportError as exc:
      raise (ref RpcPostError)(msg: exc.msg, parent: exc)

    await fut

# ---------------------------------------------------------------------------
# Message loop
# ---------------------------------------------------------------------------

proc processMessages(client: RpcPipesClient) {.async: (raises: []).} =
  let maxMessageSize =
    if client.maxMessageSize == 0: defaultMaxMessageSize else: client.maxMessageSize

  client.lastError = nil
  var lastError: ref JsonRpcError
  while not client.input.atEof():
    try:
      let data = await client.framing.recvMsg(client.input, maxMessageSize)
      if data.len == 0:
        break

      let fallback = client.callOnProcessMessage(data).valueOr:
        lastError = (ref RequestDecodeError)(msg: error, payload: data)
        break

      if not fallback:
        continue

      let resp =
        try:
          await client.processMessage(data)
        except InvalidResponse as exc:
          raise exc
        except JsonRpcError as exc:
          try:
            await client.framing.sendMsg(
              client.output, wrapError(router.INVALID_REQUEST, exc.msg)
            )
          except TransportError:
            discard
          raise exc

      if resp.len > 0:
        await client.framing.sendMsg(client.output, resp)
    except TransportIncompleteError as exc:
      debug "Pipes connection ended", err = exc.msg, remote = client.remote
      break
    except CatchableError as exc:
      lastError = (ref RpcTransportError)(msg: exc.msg, parent: exc)
      break

  if lastError == nil:
    lastError = (ref RpcTransportError)(msg: "Connection closed")
  else:
    client.lastError = (ref RpcTransportError)(msg: lastError.msg)

  # Prevent new requests
  let
    input = move(client.input)
    output = move(client.output)
  client.clearPending(lastError)

  await input.closeWait()
  await output.closeWait()

  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc attach*(
    client: RpcPipesClient,
    input, output: StreamTransport,
    remote: string,
) {.async: (raises: [], raw: true).} =
  client.input = input
  client.output = output
  client.remote = remote

  processMessages(client)

# ---------------------------------------------------------------------------
# Connecting
# ---------------------------------------------------------------------------

proc connect*(
    client: RpcPipesClient, input, output: StreamTransport, remote = "pipes"
) =
  client.loop = client.attach(input, output, remote)

method close*(client: RpcPipesClient) {.async: (raises: []).} =
  if client.loop != nil:
    let loop = move(client.loop)
    await loop.cancelAndWait()
