# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronos/unittest2/asynctests,
  ../json_rpc/[rpcclient, rpcserver],
  ./private/helpers

# Create RPC on server
proc setupServer*(srv: RpcServer) =
  srv.rpc("myProc") do(input: string, data: array[0..3, int]):
    return %("Hello " & input & " data: " & $data)

  srv.rpc("myError") do(input: string, data: array[0..3, int]):
    raise (ref ValueError)(msg: "someMessage")

  srv.rpc("invalidRequest") do():
    raise (ref InvalidRequest)(code: -32001, msg: "Unknown payload")

template callTests(client: untyped) =
  test "Successful RPC call":
    let r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.string == "\"Hello abc data: [1, 2, 3, 4]\""

  test "Missing params":
    expect(CatchableError):
      discard waitFor client.call("myProc", %[%"abc"])

  test "Error RPC call":
    expect(CatchableError): # The error type wont be translated
      discard waitFor client.call("myError", %[%"abc", %[1, 2, 3, 4]])

  test "Invalid request exception":
    try:
      discard waitFor client.call("invalidRequest", %[])
      check false
    except CatchableError as e:
      check e.msg == """{"code":-32001,"message":"Unknown payload"}"""

suite "Socket Server/Client RPC/newLine":
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

  callTests(client)

suite "Socket Server/Client RPC/httpHeader":
  setup:
    const framing = Framing.httpHeader()
    var srv = newRpcSocketServer(["127.0.0.1:0"], framing = framing)
    var client = newRpcSocketClient(framing = framing)

    srv.setupServer()
    srv.start()
    waitFor client.connect(srv.localAddress()[0])

  teardown:
    waitFor client.close()
    srv.stop()
    waitFor srv.closeWait()

  callTests(client)

suite "Socket Server/Client RPC/lengthHeaderBE32":
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

  callTests(client)

suite "Websocket Server/Client RPC":
  setup:
    var srv = newRpcWebSocketServer("127.0.0.1", Port(0))
    var client = newRpcWebSocketClient()

    srv.setupServer()
    srv.start()
    waitFor client.connect("ws://" & $srv.localAddress())

  callTests(client)

  teardown:
    waitFor client.close()
    srv.stop()
    waitFor srv.closeWait()

suite "Websocket Server/Client RPC with Compression":
  setup:
    var srv = newRpcWebSocketServer("127.0.0.1", Port(0),
                                    compression = true)
    var client = newRpcWebSocketClient()

    srv.setupServer()
    srv.start()
    waitFor client.connect("ws://" & $srv.localAddress(),
                          compression = true)

  teardown:
    waitFor client.close()
    srv.stop()
    waitFor srv.closeWait()

  callTests(client)

suite "Custom processClient":
  test "Should be able to use custom processClient":
    var wasCalled: bool = false

    proc processClientHook(server: StreamServer, transport: StreamTransport) {.async: (raises: []).} =
      wasCalled = true

    var srv = newRpcSocketServer(processClientHook)
    srv.addStreamServer("localhost", Port(8888))
    var client = newRpcSocketClient()
    srv.setupServer()
    srv.start()
    waitFor client.connect(srv.localAddress()[0])
    asyncCheck client.call("", %[])
    srv.stop()
    waitFor srv.closeWait()
    check wasCalled

template notifyTest(router, client: untyped) =
  asyncTest "notifications":
    var
      notified = newAsyncEvent()
      notified2 = newAsyncEvent()

    router[].rpc("some_notify") do() -> void:
      notified.fire()
    router[].rpc("some_notify2") do() -> void:
      notified2.fire()

    await srv.notify("some_notify", default(RequestParamsTx))
    await srv.notify("doesnt_exist", default(RequestParamsTx))
    await srv.notify("some_notify2", default(RequestParamsTx))

    check:
      await notified.wait().withTimeout(1.seconds)
      await notified2.wait().withTimeout(1.seconds)

suite "Socket Bidirectional":
  setup:
    var router = new RpcRouter

    var srv = newRpcSocketServer(["127.0.0.1:0"])
    var client = newRpcSocketClient(router = router)

    srv.start()

    waitFor client.connect(srv.localAddress()[0])

  teardown:
    waitFor client.close()

    srv.stop()
    waitFor srv.closeWait()

  notifyTest(router, client)

suite "Websocket Bidirectional":
  setup:
    var router = new RpcRouter

    var srv = newRpcWebSocketServer("127.0.0.1", Port(0))
    var client = newRpcWebSocketClient(router = router)

    srv.start()

    waitFor client.connect("ws://" & $srv.localAddress())

  teardown:
    waitFor client.close()

    srv.stop()
    waitFor srv.closeWait()

  notifyTest(router, client)
