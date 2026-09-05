# json-rpc
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/strutils,
  unittest2,
  chronos,
  stew/byteutils,
  ../json_rpc/rpcclient

proc badServer(reply: seq[byte]): StreamServer {.raises: [TransportError].} =
  ## A raw stream server that waits for a request and then answers with
  ## `reply` - which may be arbitrarily malformed - before closing.
  proc process(
      server: StreamServer, transport: StreamTransport
  ) {.async: (raises: []).} =
    try:
      var buf: array[4096, byte]
      discard await transport.readOnce(addr buf[0], buf.len)
      if reply.len > 0:
        discard await transport.write(reply)
    except CancelledError, TransportError:
      discard
    await transport.closeWait()

  createStreamServer(initTAddress("127.0.0.1", Port(0)), process, {ReuseAddr})

proc framingError(
    framing: Framing, reply: seq[byte], maxMessageSize = defaultMaxMessageSize
): string {.raises: [CancelledError, JsonRpcError, TransportError].} =
  ## return client error message when processing `reply` sent by server.
  ## `reply` should be a malformed reply.
  let srv = badServer(reply)
  srv.start()
  defer:
    srv.stop()
    waitFor srv.closeWait()

  let client = newRpcSocketClient(maxMessageSize = maxMessageSize, framing = framing)
  waitFor client.connect(srv.localAddress())
  defer:
    waitFor client.close()

  try:
    discard waitFor client.call("myProc", default(RequestParamsTx))
    "no error was raised"
  except RpcTransportError as exc:
    exc.msg
  except JsonRpcError as exc:
    "unexpected " & $exc.name & ": " & exc.msg

proc framingError(
    framing: Framing, reply: string, maxMessageSize = defaultMaxMessageSize
): string {.raises: [CancelledError, JsonRpcError, TransportError].} =
  framingError(framing, toBytes(reply), maxMessageSize)

suite "Socket framing/httpHeader":
  const framing = Framing.httpHeader()

  test "Malformed header":
    check framingError(framing, "garbage\r\n\r\n") == "Malformed message header"

  test "Empty header block":
    check framingError(framing, "\r\n\r\n") == "Malformed message header"

  test "Header without a value":
    check framingError(framing, "Content-Length\r\n\r\n") ==
      "Malformed message header"

  test "Non numeric content length":
    check framingError(framing, "Content-Length: abc\r\n\r\n") ==
      "Malformed content length"

  test "Negative content length":
    check framingError(framing, "Content-Length: -1\r\n\r\n") ==
      "Malformed content length"

  test "Overflowing content length":
    check framingError(framing, "Content-Length: 99999999999999999999999\r\n\r\n") ==
      "Malformed content length"

  test "Content length above the message size limit":
    check framingError(
      framing, "Content-Length: 1000\r\n\r\n" & "x".repeat(1000), maxMessageSize = 64
    ) == "Maximum length exceeded: 1000"

  test "Header above the header size limit":
    check framingError(framing, "x".repeat(2000)) == "Limit reached!"

  test "Truncated header":
    check framingError(framing, "Content-Length: 12\r\n") == "Data incomplete!"

  test "Truncated payload":
    check framingError(framing, "Content-Length: 100\r\n\r\nabc") == "Data incomplete!"

  test "Missing content length is treated as close":
    check framingError(framing, "Foo: bar\r\n\r\n") == "Connection closed"

  test "Zero content length is treated as close":
    check framingError(framing, "Content-Length: 0\r\n\r\n") == "Connection closed"

suite "Socket framing/lengthHeaderBE32":
  const framing = Framing.lengthHeaderBE32()

  test "Length above the message size limit":
    check framingError(framing, @[0xFF'u8, 0xFF, 0xFF, 0xFF]) ==
      "Maximum length exceeded: 4294967295"

  test "Truncated length prefix":
    check framingError(framing, @[0'u8, 0, 0]) == "Incomplete message"

  test "Missing payload":
    check framingError(framing, @[0'u8, 0, 0, 100]) == "Incomplete message"

  test "Truncated payload":
    check framingError(framing, @[0'u8, 0, 0, 100] & toBytes("abc")) ==
      "Incomplete message"

  test "Zero length message treated as close":
    check framingError(framing, @[0'u8, 0, 0, 0]) == "Connection closed"

suite "Socket framing/newLine":
  const framing = Framing.newLine()

  test "No data is treated as close":
    check framingError(framing, "") == "Connection closed"

  test "Truncated line is treated as close":
    # Empty line is indistinguishable from a closed connection
    check framingError(framing, "\r\n") == "Connection closed"
