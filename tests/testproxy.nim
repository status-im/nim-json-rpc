import
  unittest, json, chronicles,
  ../json_rpc/[rpcclient, rpcserver, rpcproxy]

let srvAddress = "localhost:8545"
var srv = newRpcHttpServer([srvAddress])

let proxySrvAddress = "localhost:8546"
var proxy = newRpcHttpProxy([proxySrvAddress])

var client = newRpcHttpClient()
let duplicatedProcedureName = "duplicated"

# Create RPC on server
srv.rpc("myProc") do(input: string, data: array[0..3, int]):
  return %("Hello " & input & " data: " & $data)

# registration of duplicated procedures needs to happen in separate scope as otherwise macro does not compile, due
# to redefinition of procedure name in scope (even if it happens on two different objects)
block:
  srv.rpc(duplicatedProcedureName) do()-> string:
    return "server"

# Create RPC on proxy server
proxy.registerProxyMethod("myProc")
proxy.registerProxyMethod(duplicatedProcedureName)

# Create standard handler on server
proxy.rpc("myProc1") do(input: string, data: array[0..3, int]):
  return %("Hello " & input & " data: " & $data)

block:
  proxy.rpc(duplicatedProcedureName) do()-> string:
    return "proxy"

srv.start()
waitFor proxy.start("localhost", Port(8545))
waitFor client.connect("localhost", Port(8546))

suite "Proxy RPC":
  test "Successful RPC call thorugh proxy":
    let r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.getStr == "Hello abc data: [1, 2, 3, 4]"
  test "Successful RPC call no proxy":
    let r = waitFor client.call("myProc1", %[%"abc", %[1, 2, 3, 4]])
    check r.getStr == "Hello abc data: [1, 2, 3, 4]"
  test "Call local method instead of proxy in case of conflict":
    let r = waitFor client.call("duplicated", %[])
    check r.getStr == "proxy"
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
