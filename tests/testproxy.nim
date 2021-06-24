import
  unittest, json, chronicles,
  ../json_rpc/[rpcclient, rpcserver, rpcproxy]

let srvAddress = "localhost:8545"
var srv = newRpcHttpServer([srvAddress])

let proxySrvAddress = "localhost:8546"
var proxy = newRpcHttpProxy([proxySrvAddress])

var client = newRpcHttpClient()

# Create RPC on server
srv.rpc("myProc") do(input: string, data: array[0..3, int]):
  return %("Hello " & input & " data: " & $data)

# Create RPC on proxy server
proxy.rpc("myProc1") do(input: string, data: array[0..3, int]):
  return %("Hello " & input & " data: " & $data)

srv.start()
waitFor proxy.init("localhost", Port(8545))
waitFor client.connect("localhost", Port(8546))

suite "Proxy RPC":
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
proxy.stop()
waitFor proxy.closeWait()
