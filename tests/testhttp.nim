# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2,
  chronos/unittest2/asynctests,
  ../json_rpc/[rpcserver, rpcclient, jsonmarshal],
  ./private/helpers,
  stew/byteutils

const TestsCount = 100
const bigChunkSize = 4 * 8192

suite "JSON-RPC/http":
  setup:
    var httpsrv = newRpcHttpServer(["127.0.0.1:0"])
    # Create RPC on server
    httpsrv.rpc("myProc") do(input: string, data: array[0 .. 3, int]):
      result = %("Hello " & input & " data: " & $data)
    httpsrv.rpc("noParamsProc") do():
      result = %("Hello world")

    httpsrv.rpc("bigchunkMethod") do() -> seq[byte]:
      result = newSeq[byte](bigChunkSize)
      for i in 0 ..< result.len:
        result[i] = byte(i mod 255)

    httpsrv.setMaxChunkSize(8192)
    httpsrv.start()
    let serverAddress = $httpsrv.localAddress()[0]

  teardown:
    waitFor httpsrv.stop()
    waitFor httpsrv.closeWait()

  asyncTest "Simple RPC call":
    var client = newRpcHttpClient()
    await client.connect("http://" & serverAddress)

    var r = await client.call("noParamsProc", %[])
    check r.string == "\"Hello world\""
    await client.close()

  asyncTest "Continuous RPC calls (" & $TestsCount & " messages)":
    var client = newRpcHttpClient()
    for i in 0 ..< TestsCount:
      await client.connect("http://" & serverAddress)
      var r = await client.call("myProc", %[%"abc", %[1, 2, 3, i]])
      check:
        r.string == "\"Hello abc data: [1, 2, 3, " & $i & "]\""
      await client.close()

  asyncTest "Invalid RPC calls":
    var client = newRpcHttpClient()
    await client.connect("http://" & serverAddress)
    expect JsonRpcError:
      discard await client.call("invalidProcA", %[])

    expect JsonRpcError:
      discard await client.call("invalidProcB", %[1, 2, 3])

    await client.close()

  asyncTest "Http client can handle chunked transfer encoding":
    var client = newRpcHttpClient()
    await client.connect("http://" & serverAddress)
    let r = await client.call("bigchunkMethod", %[])
    let data = JrpcConv.decode(r.string, seq[byte])
    check:
      data.len == bigChunkSize

    await client.close()

  asyncTest "Simple RPC notification":
    var notif = false

    httpsrv.rpc("notif") do() -> void:
      notif = true

    var client = newRpcHttpClient()
    await client.connect("http://" & serverAddress)

    await client.notify("notif", RequestParamsTx())
    await client.close()

    check:
      notif

  asyncTest "Chunked encoding":
    # The server doesn't use chunked encoding but the client might encounter
    # such servers - test that it works as expected
    let host = "127.0.0.1"
    var server = createStreamServer(initTAddress(host & ":0"), {ReuseAddr})
    defer:
      await server.closeWait()

    let port = server.localAddress().port

    proc simpleServerResponder() {.async.} =
      try:
        let conn = await server.accept()

        # 1. Consume the incoming headers but ignore the body hoping it's small
        # enough
        var headerBuf: seq[byte] = newSeq[byte](8192)
        discard
          await conn.readUntil(addr headerBuf[0], headerBuf.len, toBytes("\r\n\r\n"))

        # 2. Send HTTP response with Chunked Transfer Encoding
        var respHeader = (
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
          "Transfer-Encoding: chunked\r\n\r\n"
        ).toBytes()
        discard await conn.write(respHeader)

        # JSON Response broken into two chunks
        let fullMsg = """{"jsonrpc":"2.0","result":{"s":"part1"},"id":1}"""
        let mid = fullMsg.len div 2
        let part1 = fullMsg[0 ..< mid]
        let part2 = fullMsg[mid ..^ 1]

        # Chunk 1: size in hex + \r\n
        discard await conn.write(
          (toHex(part1.len).strip(trailing = false, chars = {'0'}) & "\r\n").toBytes()
        )
        discard await conn.write(part1.toBytes())

        # Chunk 2: size in hex + \r\n
        discard await conn.write(
          ("\r\n" & toHex(part2.len).strip(trailing = false, chars = {'0'}) & "\r\n").toBytes()
        )
        discard await conn.write(part2.toBytes())

        # Final empty chunk to end the stream (0\r\n\r\n)
        discard await conn.write("\r\n0\r\n\r\n".toBytes())
        await conn.shutdownWait()
        await conn.closeWait()
      except CatchableError as exc:
        raiseAssert exc.msg

    var st = simpleServerResponder()

    var client = newRpcHttpClient()

    try:
      await client.connect(host, port, false)

      let res = await client.call("anyMethod", %*{"param": "value"})
      check res == JsonString """{"s":"part1"}"""
    finally:
      await client.close()
    await st.cancelAndWait()
