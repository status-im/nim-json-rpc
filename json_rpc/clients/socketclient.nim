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
  ./shared/framing,
  ../[client, errors, router],
  ../private/jrpc_sys

export client, errors, framing

type
  RpcSocketClient* = ref object of RpcConnection
    ## StreamTransport-based bidirectional connection with pluggable framing
    ## options for delineating messages.
    transport*: StreamTransport
    loop*: Future[void]
    framing*: Framing

proc new*(
    T: type RpcSocketClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(RpcRouterCallback),
    framing = Framing.newLine(),
): T =
  T(maxMessageSize: maxMessageSize, router: router, framing: framing)

proc new*(
    T: type RpcSocketClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
    framing = Framing.newLine(),
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

proc newRpcSocketClient*(
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
    framing = Framing.newLine(),
): RpcSocketClient =
  ## Creates a new client instance.
  RpcSocketClient.new(maxMessageSize, router, framing)

method send*(
    client: RpcSocketClient, reqData: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if client.transport.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )
  try:
    await client.framing.sendMsg(client.transport, reqData)
  except TransportError as exc:
    raise (ref RpcPostError)(msg: exc.msg, parent: exc)

method request(
    client: RpcSocketClient, reqData: seq[byte], id: int
): Future[ResponseBatchRx] {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Remotely calls the specified RPC method.
  let transport = client.transport
  if transport.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )

  client.withPendingFut(fut, id):
    try:
      await client.framing.sendMsg(client.transport, reqData)
    except TransportError as exc:
      raise (ref RpcPostError)(msg: exc.msg, parent: exc)

    await fut

proc processMessages(client: RpcSocketClient) {.async: (raises: []).} =
  # Provide backwards compat with consumers that don't set a max message size
  # for example by constructing RpcWebSocketHandler without going through init
  let maxMessageSize =
    if client.maxMessageSize == 0: defaultMaxMessageSize else: client.maxMessageSize

  var lastError: ref JsonRpcError
  while not client.transport.atEof():
    try:
      let data = await client.framing.recvMsg(client.transport, maxMessageSize)
      if data.len == 0:
        break

      let fallback = client.callOnProcessMessage(data).valueOr:
        lastError = (ref RequestDecodeError)(msg: error, payload: data)
        break

      if not fallback:
        continue

      let resp = try:
        await client.processMessage(data)
      except InvalidResponse as exc:
        raise exc
      except JsonRpcError as exc:
        try:
          await client.framing.sendMsg(client.transport, wrapError(router.INVALID_REQUEST, exc.msg))
        except TransportError:
          discard
        raise exc

      if resp.len > 0:
        await client.framing.sendMsg(client.transport, resp)
    except CatchableError as exc:
      lastError = (ref RpcTransportError)(msg: exc.msg, parent: exc)
      break

  if lastError == nil:
    lastError = (ref RpcTransportError)(msg: "Connection closed")

  # Prevent new requests
  let transport = move(client.transport)
  client.clearPending(lastError)

  await transport.closeWait()

  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc attach*(
    client: RpcSocketClient, transport: StreamTransport, remote: string
) {.async: (raises: [], raw: true).} =
  client.transport = transport
  client.remote = remote

  processMessages(client)

proc connect*(
    client: RpcSocketClient, address: TransportAddress
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  let transport =
    try:
      await connect(address)
    except TransportError as exc:
      raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

  client.loop = client.attach(transport, $address)

proc connect*(
    client: RpcSocketClient, address: string, port: Port
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  let addresses =
    try:
      resolveTAddress(address, port)
    except TransportError as exc:
      raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

  await client.connect(addresses[0])

method close*(client: RpcSocketClient) {.async: (raises: []).} =
  if client.loop != nil:
    let loop = move(client.loop)
    await loop.cancelAndWait()
