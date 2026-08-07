# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2, chronicles,
  ../json_rpc/[rpcclient, rpcserver, rpcproxy],
  ./private/helpers,
  ./private/flavor

let srvAddress = initTAddress("127.0.0.1", Port(0))
let proxySrvAddress = "127.0.0.1:0"

template registerMethods(srv: RpcServer, proxy: RpcProxy) =
  srv.rpc("myProc") do(input: string, data: array[0..3, int]):
    %("Hello " & input & " data: " & $data)
  # Create RPC on proxy server
  proxy.registerProxyMethod("myProc")

  # Create standard handler on server
  proxy.rpc("myProc1") do(input: string, data: array[0..3, int]):
    %("Hello " & input & " data: " & $data)

  srv.rpc("myProcFlavor", JrpcFlavor) do(obj: FlavorObj) -> FlavorObj:
    FlavorObj.init("ret " & obj.s.string)

  proxy.registerProxyMethod("myProcFlavor")

  proxy.rpc("myProc1Flavor", JrpcFlavor) do(obj: FlavorObj) -> FlavorObj:
    FlavorObj.init("ret " & obj.s.string)

  proxy.rpc(JrpcFlavor):
    proc myProc1FlavorCtx(obj: FlavorObj): FlavorObj =
      FlavorObj.init("ret " & obj.s.string)

  srv.rpc(JrpcFlavor):
    proc mySrvAppErr(): FlavorObj {.raises: [RpcResponseError].} =
      raise (ref RpcResponseError)(code: 123, msg: "Some error")

  proxy.registerProxyMethod("mySrvAppErr")

template callTests(client: untyped): untyped =
  test "Successful RPC call thorugh proxy":
    let r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.string == "\"Hello abc data: [1, 2, 3, 4]\""

  test "Successful RPC call no proxy":
    let r = waitFor client.call("myProc1", %[%"abc", %[1, 2, 3, 4]])
    check r.string == "\"Hello abc data: [1, 2, 3, 4]\""

  test "Missing params":
    expect(CatchableError):
      discard waitFor client.call("myProc", %[%"abc"])

  test "Method missing on server and proxy server":
    expect(CatchableError):
      discard waitFor client.call("missingMethod", %[%"abc"])

  test "Successful RPC call thorugh proxy with flavor":
    let r = waitFor client.call("myProcFlavor", %[FlavorObj.init("foobar")])
    check r.string == """{"s":"ret foobar"}"""

  test "Successful RPC call no proxy with flavor":
    let r = waitFor client.call("myProc1Flavor", %[FlavorObj.init("foobar")])
    check r.string == """{"s":"ret foobar"}"""

  test "Successful RPC call no proxy with flavor context":
    let r = waitFor client.call("myProc1FlavorCtx", %[FlavorObj.init("foobar")])
    check r.string == """{"s":"ret foobar"}"""

  test "Application error is propagated":
    try:
      discard waitFor client.call("mySrvAppErr", %[])
      check false
    except RpcResponseError as exc:
      check:
        exc.code == 123
        exc.msg == "Some error"
        exc.data == JsonString("")

  # XXX requires https://github.com/status-im/nim-json-rpc/pull/294
  #test "Invalid params is propagated":
  #  try:
  #    discard waitFor client.call("myProc", %[123])
  #    check false
  #  except RpcInvalidParamsError as exc:
  #    check:
  #      exc.code == -32602
  #      exc.msg == "`myProc` raised an exception"
  #      exc.data == JsonString("\"Expected 2 JSON parameter(s) but got 1\"")

suite "Proxy RPC through http":
  var srv = newRpcHttpServer([srvAddress])
  var proxy = RpcProxy.new([proxySrvAddress], getHttpClientConfig("http://" & $srv.localAddress()[0]))
  var client = newRpcHttpClient()

  registerMethods(srv, proxy)

  srv.start()
  waitFor proxy.start()
  waitFor client.connect("http://" & $proxy.localAddress()[0])

  callTests(client)

  waitFor srv.stop()
  waitFor srv.closeWait()
  waitFor proxy.stop()
  waitFor proxy.closeWait()

suite "Proxy RPC through websockets":
  var srv = newRpcWebSocketServer(srvAddress)
  var proxy = RpcProxy.new([proxySrvAddress], getWebSocketClientConfig("ws://" & $srv.localAddress()))
  var client = newRpcHttpClient()

  registerMethods(srv, proxy)

  srv.start()
  waitFor proxy.start()
  waitFor client.connect("http://" & $proxy.localAddress()[0])

  callTests(client)

  srv.stop()
  waitFor srv.closeWait()
  waitFor proxy.stop()
  waitFor proxy.closeWait()
