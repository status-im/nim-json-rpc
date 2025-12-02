# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2, chronos/unittest2/asynctests,
  ../json_rpc/[rpcserver, rpcclient, jsonmarshal],
  ./private/helpers

const TestsCount = 100
const bigChunkSize = 4 * 8192

suite "JSON-RPC/http":
  setup:
    var httpsrv = newRpcHttpServer(["127.0.0.1:0"])
    # Create RPC on server
    httpsrv.rpc("myProc") do(input: string, data: array[0..3, int]):
      result = %("Hello " & input & " data: " & $data)
    httpsrv.rpc("noParamsProc") do():
      result = %("Hello world")

    httpsrv.rpc("bigchunkMethod") do() -> seq[byte]:
      result = newSeq[byte](bigChunkSize)
      for i in 0..<result.len:
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
    for i in 0..<TestsCount:
      await client.connect("http://" & serverAddress)
      var r = await client.call("myProc", %[%"abc", %[1, 2, 3, i]])
      check: r.string == "\"Hello abc data: [1, 2, 3, " & $i & "]\""
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
