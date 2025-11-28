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
  std/uri,
  chronicles,
  websock/[websock, extensions/compression/deflate],
  chronos/apps/http/httptable,
  ../[client, errors, router],
  ../private/jrpc_sys

export client, errors

type
  RpcWebSocketClient* = ref object of RpcClient
    transport*: WSSession
    uri*: Uri
    loop*: Future[void]
    getHeaders*: GetJsonRpcRequestHeaders

proc new*(
    T: type RpcWebSocketClient,
    getHeaders: GetJsonRpcRequestHeaders = nil,
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
): T =
  T(getHeaders: getHeaders, maxMessageSize: maxMessageSize, router: router)

proc newRpcWebSocketClient*(
    getHeaders: GetJsonRpcRequestHeaders = nil,
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
): RpcWebSocketClient =
  ## Creates a new client instance.
  RpcWebSocketClient.new(getHeaders, maxMessageSize, router)

method send*(
    client: RpcWebSocketClient, reqData: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if client.transport.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )
  try:
    await client.transport.send(reqData, Opcode.Binary)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise (ref RpcPostError)(msg: exc.msg, parent: exc)

method request*(
    client: RpcWebSocketClient, reqData: seq[byte]
): Future[seq[byte]] {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Remotely calls the specified RPC method.
  let transport = client.transport
  if transport.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )

  client.withPendingFut(fut):
    try:
      await transport.send(reqData, Opcode.Binary)
    except CatchableError as exc:
      # If there's an error sending, the "next messages" facility will be
      # broken since we don't know if the server observed the message or not -
      # the same goes for cancellation during write
      try:
        await noCancel transport.close()
      except CatchableError as exc:
        # TODO https://github.com/status-im/nim-websock/pull/178
        raiseAssert exc.msg
      raise (ref RpcPostError)(msg: exc.msg, parent: exc)

    await fut

proc processData(client: RpcWebSocketClient) {.async: (raises: []).} =
  var lastError: ref JsonRpcError
  while client.transport.readyState != ReadyState.Closed:
    var data =
      try:
        await client.transport.recvMsg(client.maxMessageSize)
      except CatchableError as exc:
        lastError = (ref RpcTransportError)(msg: exc.msg, parent: exc)
        break

    let resp = await(client.processMessage(data)).valueOr:
      lastError = (ref RequestDecodeError)(msg: error, payload: data)
      break

    if resp.len > 0:
      try:
        await client.transport.send(resp)
      except CatchableError as exc:
        lastError = (ref RpcTransportError)(msg: exc.msg, parent: exc)
        break

  if lastError == nil:
    lastError = (ref RpcTransportError)(msg: "Connection closed")

  client.clearPending(lastError)

  try:
    await noCancel client.transport.close()
    client.transport = nil
  except CatchableError as exc:
    # TODO https://github.com/status-im/nim-websock/pull/178
    raiseAssert exc.msg

  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc addExtraHeaders(
    headers: var HttpTable,
    client: RpcWebSocketClient,
    extraHeaders: HttpTable) =
  # Apply client instance overrides
  if client.getHeaders != nil:
    for header in client.getHeaders():
      headers.add(header[0], header[1])

  # Apply call specific overrides
  for header in extraHeaders.stringItems:
    headers.add(header.key, header.value)

  # Apply default origin
  discard headers.hasKeyOrPut("Origin", "http://localhost")

proc connect*(
    client: RpcWebSocketClient,
    uri: string,
    extraHeaders: HttpTable = default(HttpTable),
    compression = false,
    hooks: seq[Hook] = @[],
    flags: set[TLSFlags] = {}) {.async: (raises: [CancelledError, JsonRpcError]).} =
  proc headersHook(ctx: Hook, headers: var HttpTable): Result[void, string] =
    headers.addExtraHeaders(client, extraHeaders)
    ok()
  var ext: seq[ExtFactory] = if compression: @[deflateFactory()]
                              else: @[]
  let uri = parseUri(uri)
  let ws = try:
    await WebSocket.connect(
      uri=uri,
      factories=ext,
      hooks=hooks & Hook(append: headersHook),
      flags=flags)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    # TODO https://github.com/status-im/nim-websock/pull/178
    raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

  client.transport = ws
  client.uri = uri
  client.remote = uri.hostname & ":" & uri.port
  client.loop = processData(client)

method close*(client: RpcWebSocketClient) {.async: (raises: []).} =
  await client.loop.cancelAndWait()
