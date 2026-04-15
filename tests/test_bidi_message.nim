# json-rpc
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronos/unittest2/asynctests,
  stew/byteutils,
  ../json_rpc/[rpcclient, rpcserver],
  ./private/helpers,
  ./private/flavor

proc setupServer*(srv: RpcServer) =
  srv.rpc(JrpcFlavor):
    proc rets(s: string): string =
      return "ret " & s

    proc invalid(s: string): string =
      return "ret " & s

createRpcSigsFromNim(RpcClient, JrpcFlavor):
  proc rets(s: string): string
  proc invalid(s: int): string

suite "Socket Server/Client":
  setup:
    const framing = Framing.newLine()
    var srv = newRpcSocketServer(["127.0.0.1:0"], framing = framing)
    var client = newRpcSocketClient(framing = framing)

    srv.setupServer()
    srv.start()
    waitFor client.connect(srv.localAddress()[0])

  teardown:
    waitFor client.close()
    srv.stop()
    waitFor srv.closeWait()

  test "Successful RPC call":
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

  test "Successful RPC batch call":
    let batch = client.prepareBatch()
    batch.rets("foobar")
    let res = waitFor batch.send()
    check:
      res.isOk
      res.get()[0].error.isNone
      res.get()[0].result.string == """"ret foobar""""

  test "Invalid request param":
    expect(JsonRpcError):
      discard waitFor client.call("rets", %[], JrpcFlavor)
    # following requests still work
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

  test "Invalid request batch param":
    let batch = client.prepareBatch()
    batch.invalid(123)
    batch.rets("foobar")
    batch.invalid(456)
    let res = waitFor batch.send()
    check:
      res.isOk
      res.get()[0].error.isSome
      res.get()[1].error.isNone
      res.get()[2].error.isSome
    # following requests still work
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

  test "Sending an ambiguous message kills the conn":
    var fut = newFuture[void]()
    client.onDisconnect = proc () {.gcsafe, raises: [].} =
      fut.complete()
    waitFor client.send("""{"foo": "boo"}""".toBytes)
    waitFor fut
    expect(RpcTransportError):
      discard waitFor client.rets("foobar")
    # check the server is still running
    var client2 = newRpcSocketClient(framing = framing)
    waitFor client2.connect(srv.localAddress()[0])
    let r1 = waitFor client2.rets("foobar")
    check r1 == "ret foobar"
    waitFor client2.close()

  test "Sending an ambiguous batch message kills the conn":
    var fut = newFuture[void]()
    client.onDisconnect = proc () {.gcsafe, raises: [].} =
      fut.complete()
    waitFor client.send("""[{"foo": "boo"}]""".toBytes)
    waitFor fut
    expect(RpcTransportError):
      discard waitFor client.rets("foobar")
    # check the server is still running
    var client2 = newRpcSocketClient(framing = framing)
    waitFor client2.connect(srv.localAddress()[0])
    let r1 = waitFor client2.rets("foobar")
    check r1 == "ret foobar"
    waitFor client2.close()
