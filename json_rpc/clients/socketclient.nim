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
  stew/byteutils,
  chronicles,
  ../[client, errors, router],
  ../private/jrpc_sys

export client, errors

type
  RpcSocketClient* = ref object of RpcConnection
    transport*: StreamTransport
    address*: TransportAddress
    loop*: Future[void]

proc new*(
    T: type RpcSocketClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
): T =
  let router =
    if router != nil:
      proc(request: RequestBatchRx): Future[string] {.async: (raises: [], raw: true).} =
        router[].route(request)
    else:
      nil

  T(maxMessageSize: maxMessageSize, router: router)

proc newRpcSocketClient*(
    maxMessageSize = defaultMaxMessageSize, router = default(ref RpcRouter)
): RpcSocketClient =
  ## Creates a new client instance.
  RpcSocketClient.new(maxMessageSize, router)

method send*(
    client: RpcSocketClient, reqData: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if client.transport.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )
  try:
    discard await client.transport.write(reqData & "\r\n".toBytes())
  except CancelledError as exc:
    raise exc
  except TransportError as exc:
    raise (ref RpcPostError)(msg: exc.msg, parent: exc)

method request(
    client: RpcSocketClient, reqData: seq[byte]
): Future[seq[byte]] {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Remotely calls the specified RPC method.
  let transport = client.transport
  if transport.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )

  client.withPendingFut(fut):
    try:
      discard await transport.write(reqData & "\r\n".toBytes())
    except CatchableError as exc:
      # If there's an error sending, the "next messages" facility will be
      # broken since we don't know if the server observed the message or not
      transport.close()
      raise (ref RpcPostError)(msg: exc.msg, parent: exc)

    await fut

proc processMessages*(client: RpcSocketClient) {.async: (raises: []).} =
  # Provide backwards compat with consumers that don't set a max message size
  # for example by constructing RpcWebSocketHandler without going through init
  let maxMessageSize =
    if client.maxMessageSize == 0: defaultMaxMessageSize else: client.maxMessageSize

  var lastError: ref JsonRpcError
  while true:
    try:
      let data = await client.transport.readLine(maxMessageSize)
      if data == "":
        break

      let resp = await(client.processMessage(data.toBytes())).valueOr:
        lastError = (ref RequestDecodeError)(msg: error, payload: data.toBytes())
        break

      if resp.len > 0:
        discard await client.transport.write(resp & "\r\n")
    except CatchableError as exc:
      lastError = (ref RpcTransportError)(msg: exc.msg, parent: exc)
      break

  if lastError == nil:
    lastError = (ref RpcTransportError)(msg: "Connection closed")

  client.clearPending(lastError)

  await client.transport.closeWait()
  client.transport = nil
  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc connect*(
    client: RpcSocketClient, address: TransportAddress
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  client.transport =
    try:
      await connect(address)
    except TransportError as exc:
      raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

  client.address = address
  client.remote = $client.address
  client.loop = processMessages(client)

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
  await client.loop.cancelAndWait()
  if not client.transport.isNil:
    client.transport.close()
    client.transport = nil
