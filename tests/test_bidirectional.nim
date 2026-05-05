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

template checkInvalidMessage(client: untyped, req, expectedErr: string): untyped =
  # check sending `req` terminates the connection with `expectedErr` error
  var disconnFut = newFuture[void]()
  client.onDisconnect = proc () {.gcsafe, raises: [].} =
    disconnFut.complete()
  let fut1 = client.send(req.toBytes)
  let fut2 = client.rets("foobar")
  waitFor fut1
  waitFor disconnFut
  try:
    discard waitFor fut2
    doAssert false
  except RpcTransportError as err:
    doAssert err.parent != nil
    check err.parent.msg == expectedErr
  # following requests won't work
  expect RpcTransportError:
    discard waitFor client.rets("foobar")

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

  test "Sending an unknown id is ignored":
    const req = """{"jsonrpc": "2.0", "method": "foo", "id": 123123}"""
    waitFor client.send(req.toBytes)
    # following requests still work
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

  test "Sending an unknown id within a batch is ignored":
    const req = """[{"jsonrpc": "2.0", "method": "foo", "id": 123123}]"""
    waitFor client.send(req.toBytes)
    # following requests still work
    let r1 = waitFor client.rets("foobar")
    check r1 == "ret foobar"

  test "Sending an ambiguous message terminates the connection":
    # check it fails with parse error; id=null response
    const req = """{"foo": "boo"}"""
    const expected = """{"code":-32600,"message":"',' expected"}"""
    checkInvalidMessage(client, req, expected)

  test "Sending an ambiguous batch message terminates the connection":
    const req = """[{"foo": "boo"}]"""
    const expected = """{"code":-32600,"message":"',' expected"}"""
    checkInvalidMessage(client, req, expected)

  test "Sending a null id terminates the connection":
    # note this terminates the connection when receiving the null id response
    const req = """{"jsonrpc": "2.0", "method": "foo", "id": null}"""
    const expected = """{"code":-32601,"message":"'foo' is not a registered RPC method"}"""
    checkInvalidMessage(client, req, expected)

  test "Sending a null id within a batch terminates the connection":
    const req = """[{"jsonrpc": "2.0", "method": "foo", "id": null}]"""
    const expected = """{"code":-32601,"message":"'foo' is not a registered RPC method"}"""
    checkInvalidMessage(client, req, expected)

  test "Sending a null id terminates the connection; variant":
    const req = """{"jsonrpc": "2.0", "method": "rets", "params": ["foo"], "id": null}"""
    const expected = "Unexpected response result with id = null"
    checkInvalidMessage(client, req, expected)

  test "Sending a null id within a batch terminates the connection; variant":
    const req = """[{"jsonrpc": "2.0", "method": "rets", "params": ["foo"], "id": null}]"""
    const expected = "Unexpected response result with id = null"
    checkInvalidMessage(client, req, expected)

  test "Sending a string id terminates the connection":
    # note this terminates the connection when receiving the string id response
    const req = """{"jsonrpc": "2.0", "method": "foo", "id": "123123"}"""
    const expected = "Unexpected response with string id = 123123"
    checkInvalidMessage(client, req, expected)

  test "Sending a string id within a batch terminates the connection":
    const req = """[{"jsonrpc": "2.0", "method": "foo", "id": "123123"}]"""
    const expected = "Unexpected response with string id = 123123"
    checkInvalidMessage(client, req, expected)

suite "Test bidirectional socket server/client":
  setup:
    # XXX Framing.lengthHeaderBE32()
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
