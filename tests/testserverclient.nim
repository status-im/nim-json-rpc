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
  ../json_rpc/[rpcclient, rpcserver]

# Create RPC on server
proc setupServer*(srv: RpcServer) =
  srv.rpc("myProc") do(input: string, data: array[0..3, int]):
    return %("Hello " & input & " data: " & $data)

  srv.rpc("myError") do(input: string, data: array[0..3, int]):
    raise (ref ValueError)(msg: "someMessage")

  srv.rpc("invalidRequest") do():
    raise (ref InvalidRequest)(code: -32001, msg: "Unknown payload")

suite "Socket Server/Client RPC":
  var srv = newRpcSocketServer(["127.0.0.1:0"])
  var client = newRpcSocketClient()

  srv.setupServer()
  srv.start()
  waitFor client.connect(srv.localAddress()[0])

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

  srv.stop()
  waitFor srv.closeWait()

suite "Websocket Server/Client RPC":
  var srv = newRpcWebSocketServer("127.0.0.1", Port(0))
  var client = newRpcWebSocketClient()

  srv.setupServer()
  srv.start()
  waitFor client.connect("ws://" & $srv.localAddress())

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

  srv.stop()
  waitFor srv.closeWait()

suite "Websocket Server/Client RPC with Compression":
  var srv = newRpcWebSocketServer("127.0.0.1", Port(0),
                                  compression = true)
  var client = newRpcWebSocketClient()

  srv.setupServer()
  srv.start()
  waitFor client.connect("ws://" & $srv.localAddress(),
                         compression = true)

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

  srv.stop()
  waitFor srv.closeWait()

