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
  stew/[arrayops, byteutils, endians2],
  std/strformat,
  chronicles,
  ../[client, errors, router],
  ../private/jrpc_sys,
  httputils

export client, errors

when not declared(newSeqUninit): # nim 2.2+
  template newSeqUninit[T: byte](len: int): seq[byte] =
    newSeqUninitialized[byte](len)

type
  RpcSocketClient* = ref object of RpcConnection
    ## StreamTransport-based bidirectional connection with pluggable framing
    ## options for delineating messages.
    transport*: StreamTransport
    address*: TransportAddress
    loop*: Future[void]
    framing*: Framing

  Framing* = object
    recvMsg: proc(transport: StreamTransport, limit: int): Future[seq[byte]] {.
      async: (raises: [CancelledError, TransportError]), nimcall
    .}
    sendMsg: proc(transport: StreamTransport, sendMsg: seq[byte]) {.
      async: (raises: [CancelledError, TransportError]), nimcall
    .}

proc recvMsgNewLine(
    transport: StreamTransport, maxMessageSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, TransportError]).} =
  let data = await transport.readLine(maxMessageSize, sep = "\r\n")
  toBytes(data)

proc sendMsgNewLine(
    transport: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  discard await transport.write(msg & toBytes("\r\n"))

proc newLine*(
    T: type Framing
): T {.deprecated: "Prefer lengthHeaderBE32 or httpHeader in in new applications".} =
  ## A framing that suffixes messages with "\r\n". This framing is supported
  ## only for historical purposes and may be removed in a future version.
  ##
  ## The framing can only be used with payloads that do not contain newlines and
  ## message length is checked only after that many bytes have been transmitted.
  T(recvMsg: recvMsgNewLine, sendMsg: sendMsgNewLine)

proc recvMsgHttpHeader(
    transport: StreamTransport, maxMessageSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, TransportError]).} =
  var buf {.noinit.}: array[1024, byte]
  let
    bytes = await transport.readUntil(addr buf[0], buf.len, toBytes("\r\n\r\n"))
    headers = parseHeaders(buf.toOpenArray(0, bytes - 1), true)

  let len = headers.contentLength()
  if len <= 0 or len > maxMessageSize:
    return

  result = newSeqUninit[byte](len)
  await transport.readExactly(addr result[0], result.len)

proc sendMsgHttpHeader(
    transport: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  discard await transport.write(&"Content-Length: {msg.len}\r\n\r\n")
  discard await transport.write(msg)

proc httpHeader*(T: type Framing): T =
  ## Framing using a HTTP-like `Content-Length: <length>\r\n` header followed by
  ## an empty line ("\r\n") followed by a the message itself.
  ##
  ## This encoding is compatible with the default encoding used by StreamJsonRPC
  ## and https://www.npmjs.com/package/vscode-jsonrpc.
  ##
  ## For a higher-performance option, use `Framing.lengthHeaderBE32`.

  T(recvMsg: recvMsgHttpHeader, sendMsg: sendMsgHttpHeader)

proc recvMsgLengthHeaderBE32(
    transport: StreamTransport, maxMessageSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, TransportError]).} =
  var
    pos: int
    lenBE32: array[4, byte]
    payload: seq[byte]
    error: ref TransportError

  proc predicate(data: openArray[byte]): tuple[consumed: int, done: bool] =
    var dataPos = 0

    if payload.len == 0:
      let n = lenBE32.toOpenArray(pos, lenBE32.high()).copyFrom(data)
      pos += n

      if pos < 4:
        return (n, false)

      dataPos += n

      let messageSize = uint32.fromBytesBE(lenBE32)
      if uint64(messageSize) > uint64(maxMessageSize):
        error =
          (ref TransportLimitError)(msg: "Maximum length exceeded: " & $messageSize)
        return (n, true)

      if messageSize == 0:
        return (n, true)

      payload = newSeqUninit[byte](int(messageSize))
      pos = 0

    let n = payload.toOpenArray(pos, payload.high()).copyFrom(
        data.toOpenArray(dataPos, data.high())
      )

    pos += n

    (n, pos == payload.len())

  await transport.readMessage(predicate)

  if error != nil:
    raise error

  payload

proc sendMsgLengthHeaderBE32(
    transport: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  let header = msg.len.uint32.toBytesBE()
  discard await transport.write(addr header[0], header.len)
  discard await transport.write(msg)

proc lengthHeaderBE32*(T: type Framing): T =
  ## Framing using a HTTP-like `Content-Length` header followed by two newlines
  ## to delimit each message.
  T(recvMsg: recvMsgLengthHeaderBE32, sendMsg: sendMsgLengthHeaderBE32)

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

  T(maxMessageSize: maxMessageSize, router: router, framing: framing)

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
      await client.framing.sendMsg(client.transport, reqData)
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
      let data = await client.framing.recvMsg(client.transport, maxMessageSize)
      if data.len == 0:
        break

      let fallback = client.callOnProcessMessage(data).valueOr:
        lastError = (ref RequestDecodeError)(msg: error, payload: data)
        break

      if not fallback:
        continue

      let resp = await client.processMessage(data)

      if resp.len > 0:
        await client.framing.sendMsg(client.transport, resp)
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

method close*(client: RpcSocketClient) {.async: (raises: [], raw: true).} =
  client.loop.cancelAndWait()
