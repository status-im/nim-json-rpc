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
  chronos,
  httputils

export chronos

when not declared(newSeqUninit): # nim 2.2+
  template newSeqUninit[T: byte](len: int): seq[byte] =
    newSeqUninitialized[byte](len)

type
  RecvMsg* = proc(transport: StreamTransport, limit: int): Future[seq[byte]] {.
    async: (raises: [CancelledError, TransportError]), nimcall
  .}

  SendMsg* = proc(transport: StreamTransport, msg: seq[byte]) {.
    async: (raises: [CancelledError, TransportError]), nimcall
  .}

  Framing* = object
    recvMsg*: RecvMsg
    sendMsg*: SendMsg

proc init*(T: type Framing, recvMsg: RecvMsg, sendMsg: SendMsg): T =
  T(recvMsg: recvMsg, sendMsg: sendMsg)

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
  let bytes = await transport.readUntil(addr buf[0], buf.len, toBytes("\r\n\r\n"))

  let headers = parseHeaders(buf.toOpenArray(0, bytes - 1), true)
  if headers.failed():
    raise (ref TransportError)(msg: "Malformed message header")

  let len = headers.contentLength()
  if len < 0:
    raise (ref TransportError)(msg: "Malformed content length")
  if len > maxMessageSize:
    raise (ref TransportLimitError)(msg: "Maximum length exceeded: " & $len)
  if len == 0:
    return

  result = newSeqUninit[byte](len)
  await transport.readExactly(addr result[0], result.len)

proc sendMsgHttpHeader(
    transport: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  const field = toBytes("Content-Length: ")
  const separator = toBytes("\r\n\r\n")
  discard await transport.write(field & toBytes($msg.len) & separator & msg)

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
    if data.len == 0:
      return (0, true)

    var dataPos = 0

    if payload.len == 0:
      let n = lenBE32.toOpenArray(pos, lenBE32.high()).copyFrom(data)
      pos += n
      dataPos += n

      if pos < 4:
        return (dataPos, false)

      let messageSize = uint32.fromBytesBE(lenBE32)
      if uint64(messageSize) > uint64(maxMessageSize):
        error =
          (ref TransportLimitError)(msg: "Maximum length exceeded: " & $messageSize)
        return (dataPos, true)

      if messageSize == 0:
        return (dataPos, true)

      payload = newSeqUninit[byte](int(messageSize))
      pos = 0

    let n = payload.toOpenArray(pos, payload.high()).copyFrom(
        data.toOpenArray(dataPos, data.high())
      )

    pos += n
    dataPos += n

    (dataPos, pos == payload.len())

  await transport.readMessage(predicate)

  if error != nil:
    raise error

  payload

proc sendMsgLengthHeaderBE32(
    transport: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  var header = msg.len.uint32.toBytesBE()
  discard await transport.write(@header & msg)

proc lengthHeaderBE32*(T: type Framing): T =
  ## Framing using a big-endian 32-bit length prefix.
  T(recvMsg: recvMsgLengthHeaderBE32, sendMsg: sendMsgLengthHeaderBE32)

{.pop.}
