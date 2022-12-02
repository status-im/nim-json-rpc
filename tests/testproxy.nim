import
  unittest2, chronicles,
  ../json_rpc/[rpcclient, rpcserver, rpcproxy]

let srvAddress = initTAddress("127.0.0.1",  Port(8545))
let proxySrvAddress = "localhost:8546"
let proxySrvAddressForClient = "http://"&proxySrvAddress

template registerMethods(srv: RpcServer, proxy: RpcProxy) =
  srv.rpc("myProc") do(input: string, data: array[0..3, int]):
    return %("Hello " & input & " data: " & $data)
  # Create RPC on proxy server
  proxy.registerProxyMethod("myProc")

  # Create standard handler on server
  proxy.rpc("myProc1") do(input: string, data: array[0..3, int]):
    return %("Hello " & input & " data: " & $data)

suite "Proxy RPC through http":
  var srv = newRpcHttpServer([srvAddress])
  var proxy = RpcProxy.new([proxySrvAddress], getHttpClientConfig("http://127.0.0.1:8545"))
  var client = newRpcHttpClient()

  registerMethods(srv, proxy)

  srv.start()
  waitFor proxy.start()
  waitFor client.connect(proxySrvAddressForClient)

  test "Successful RPC call thorugh proxy":
    let r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.getStr == "Hello abc data: [1, 2, 3, 4]"
  test "Successful RPC call no proxy":
    let r = waitFor client.call("myProc1", %[%"abc", %[1, 2, 3, 4]])
    check r.getStr == "Hello abc data: [1, 2, 3, 4]"
  test "Missing params":
    expect(CatchableError):
      discard waitFor client.call("myProc", %[%"abc"])
  test "Method missing on server and proxy server":
    expect(CatchableError):
      discard waitFor client.call("missingMethod", %[%"abc"])

  waitFor srv.stop()
  waitFor srv.closeWait()
  waitFor proxy.stop()
  waitFor proxy.closeWait()

suite "Proxy RPC through websockets":
  var srv = newRpcWebSocketServer(srvAddress)
  var proxy = RpcProxy.new([proxySrvAddress], getWebSocketClientConfig("ws://127.0.0.1:8545"))
  var client = newRpcHttpClient()

  registerMethods(srv, proxy)

  srv.start()
  waitFor proxy.start()
  waitFor client.connect(proxySrvAddressForClient)

  test "Successful RPC call thorugh proxy":
    let r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.getStr == "Hello abc data: [1, 2, 3, 4]"
  test "Successful RPC call no proxy":
    let r = waitFor client.call("myProc1", %[%"abc", %[1, 2, 3, 4]])
    check r.getStr == "Hello abc data: [1, 2, 3, 4]"
  test "Missing params":
    expect(CatchableError):
      discard waitFor client.call("myProc", %[%"abc"])
  test "Method missing on server and proxy server":
    expect(CatchableError):
      discard waitFor client.call("missingMethod", %[%"abc"])

  srv.stop()
  waitFor srv.closeWait()
  waitFor proxy.stop()
  waitFor proxy.closeWait()
