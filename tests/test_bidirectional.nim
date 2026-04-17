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

template allTests(client: untyped) =
  test "Successful RPC call":
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"
    check client.pendingRequests.len == 0

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

  test "Request with null id terminates the connection":
    # the response will contain a null id
    var disconnFut = newFuture[void]()
    client.onDisconnect = proc () {.gcsafe, raises: [].} =
      disconnFut.complete()
    let fut1 = client.send("""{"jsonrpc": "2.0", "method": "foobar", "id": null}""".toBytes)
    let fut2 = client.rets("foobar")
    waitFor fut1
    waitFor disconnFut
    try:
      discard waitFor fut2
      doAssert false
    except RpcTransportError as err:
      # check it fails with method not found; id=null response
      check err.parent.msg == """{"code":-32601,"message":"'foobar' is not a registered RPC method"}"""
    # following requests won't work
    expect RpcTransportError:
      discard waitFor client.rets("foobar")

  test "Sending an ambiguous message terminates the connection":
    var disconnFut = newFuture[void]()
    client.onDisconnect = proc () {.gcsafe, raises: [].} =
      disconnFut.complete()
    let fut1 = client.send("""{"foo": "boo"}""".toBytes)
    let fut2 = client.rets("foobar")
    waitFor fut1
    waitFor disconnFut
    try:
      discard waitFor fut2
      doAssert false
    except RpcTransportError as err:
      # check it fails with parse error; id=null response
      check err.parent.msg == """{"code":-32600,"message":"',' expected"}"""
    # following requests won't work
    expect RpcTransportError:
      discard waitFor client.rets("foobar")

  test "Sending an ambiguous batch message terminates the connection":
    var disconnFut = newFuture[void]()
    client.onDisconnect = proc () {.gcsafe, raises: [].} =
      disconnFut.complete()
    let fut1 = client.send("""[{"foo": "boo"}]""".toBytes)
    let fut2 = client.rets("foobar")
    waitFor fut1
    waitFor disconnFut
    try:
      discard waitFor fut2
      doAssert false
    except RpcTransportError as err:
      # check it fails with parse error; id=null response
      check err.parent.msg == """{"code":-32600,"message":"',' expected"}"""
    # following requests won't work
    expect RpcTransportError:
      discard waitFor client.rets("foobar")

  test "Sending a response with id null terminates the connection":
    var disconnFut = newFuture[void]()
    client.onDisconnect = proc () {.gcsafe, raises: [].} =
      disconnFut.complete()
    const resp = """{"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null}"""
    waitFor client.send(resp.toBytes)
    waitFor disconnFut

  test "Sending a batch response with id null terminates the connection":
    var disconnFut = newFuture[void]()
    client.onDisconnect = proc () {.gcsafe, raises: [].} =
      disconnFut.complete()
    const resp = """[{"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null}]"""
    waitFor client.send(resp.toBytes)
    waitFor disconnFut

  test "Sending an unknown id is ignored":
    const resp = """{"jsonrpc": "2.0", "result": 7, "id": 123123}"""
    waitFor client.send(resp.toBytes)
    # following requests still work
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

  test "Sending a batch with an unknown id is ignored":
    const resp = """[{"jsonrpc": "2.0", "result": 7, "id": 123123}]"""
    waitFor client.send(resp.toBytes)
    # following requests still work
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

  test "Sending a string id is ignored":
    const resp = """{"jsonrpc": "2.0", "result": 7, "id": "123123"}"""
    waitFor client.send(resp.toBytes)
    # following requests still work
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

  test "Sending a batch with a string id is ignored":
    const resp = """[{"jsonrpc": "2.0", "result": 7, "id": "123123"}]"""
    waitFor client.send(resp.toBytes)
    # following requests still work
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

suite "Test bidirectional socket server/client":
  setup:
    const framing = Framing.lengthHeaderBE32()
    var srv = newRpcSocketServer(["127.0.0.1:0"], framing = framing)
    var client = newRpcSocketClient(framing = framing)

    srv.setupServer()
    srv.start()
    waitFor client.connect(srv.localAddress()[0])

  teardown:
    waitFor client.close()
    srv.stop()
    waitFor srv.closeWait()

  allTests(client)

suite "Test bidirectional websocket server/client":
  setup:
    var srv = newRpcWebSocketServer("127.0.0.1", Port(0))
    var client = newRpcWebSocketClient()

    srv.setupServer()
    srv.start()
    waitFor client.connect("ws://" & $srv.localAddress())

  teardown:
    waitFor client.close()
    srv.stop()
    waitFor srv.closeWait()

  allTests(client)
