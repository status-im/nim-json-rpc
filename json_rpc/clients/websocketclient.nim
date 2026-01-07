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

type RpcWebSocketClient* = ref object of RpcConnection
  transport*: WSSession
  loop: Future[void]
  getHeaders*: GetJsonRpcRequestHeaders

proc new*(
    T: type RpcWebSocketClient,
    getHeaders: GetJsonRpcRequestHeaders = nil,
    maxMessageSize = defaultMaxMessageSize,
    router = default(RpcRouterCallback),
): T =
  T(getHeaders: getHeaders, maxMessageSize: maxMessageSize, router: router)

proc new*(
    T: type RpcWebSocketClient,
    getHeaders: GetJsonRpcRequestHeaders = nil,
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
): T =
  let router =
    if router != nil:
      proc(
          request: RequestBatchRx
      ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
        router[].route(request)
    else:
      nil

  T.new(getHeaders, maxMessageSize, router)

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
      # broken since we don't know if the server observed the message or not
      try:
        await noCancel transport.close()
      except CatchableError as exc:
        # TODO https://github.com/status-im/nim-websock/pull/178
        raiseAssert exc.msg
      raise (ref RpcPostError)(msg: exc.msg, parent: exc)

    await fut

proc processMessages(client: RpcWebSocketClient) {.async: (raises: []).} =
  # Provide backwards compat with consumers that don't set a max message size
  # for example by constructing RpcWebSocketHandler without going through init
  let maxMessageSize =
    if client.maxMessageSize == 0: defaultMaxMessageSize else: client.maxMessageSize

  var lastError: ref JsonRpcError
  while client.transport.readyState != ReadyState.Closed:
    try:
      let data = await client.transport.recvMsg(maxMessageSize)

      let fallback = client.callOnProcessMessage(data).valueOr:
        lastError = (ref RequestDecodeError)(msg: error, payload: data)
        break

      if not fallback:
        continue

      let resp = await client.processMessage(data)

      if resp.len > 0:
        await client.transport.send(resp, Opcode.Binary)
    except CatchableError as exc:
      lastError = (ref RpcTransportError)(msg: exc.msg, parent: exc)
      break

  if lastError == nil:
    lastError = (ref RpcTransportError)(msg: "Connection closed")

  # Prevent new requests
  let transport = move(client.transport)
  client.clearPending(lastError)

  try:
    await noCancel transport.close()
  except CatchableError as exc:
    # TODO https://github.com/status-im/nim-websock/pull/178
    raiseAssert exc.msg

  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc addExtraHeaders(
    headers: var HttpTable, client: RpcWebSocketClient, extraHeaders: HttpTable
) =
  # Apply client instance overrides
  if client.getHeaders != nil:
    for header in client.getHeaders():
      headers.add(header[0], header[1])

  # Apply call specific overrides
  for header in extraHeaders.stringItems:
    headers.add(header.key, header.value)

  # Apply default origin
  discard headers.hasKeyOrPut("Origin", "http://localhost")

proc attach*(
    client: RpcWebSocketClient, session: WSSession, remote: string
) {.async: (raises: [], raw: true).} =
  client.transport = session
  client.remote = remote

  processMessages(client)

proc connect*(
    client: RpcWebSocketClient,
    uri: string,
    extraHeaders: HttpTable = default(HttpTable),
    compression = false,
    hooks: seq[Hook] = @[],
    flags: set[TLSFlags] = {},
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  proc headersHook(ctx: Hook, headers: var HttpTable): Result[void, string] =
    headers.addExtraHeaders(client, extraHeaders)
    ok()

  var ext: seq[ExtFactory] =
    if compression:
      @[deflateFactory()]
    else:
      @[]
  let uri = parseUri(uri)
  let ws =
    try:
      await WebSocket.connect(
        uri = uri,
        factories = ext,
        hooks = hooks & Hook(append: headersHook),
        flags = flags,
      )
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      # TODO https://github.com/status-im/nim-websock/pull/178
      raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

  client.loop = client.attach(ws, uri.hostname & ":" & uri.port)

method close*(client: RpcWebSocketClient) {.async: (raises: []).} =
  if client.loop != nil:
    let loop = move(client.loop)
    await loop.cancelAndWait()
