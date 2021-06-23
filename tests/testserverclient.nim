import
  unittest, json, chronicles,
  ../json_rpc/[rpcclient, rpcserver]

# Create RPC on server
proc setupServer*(srv: RpcServer) =
  srv.rpc("myProc") do(input: string, data: array[0..3, int]):
    return %("Hello " & input & " data: " & $data)

  srv.rpc("myError") do(input: string, data: array[0..3, int]):
    raise (ref ValueError)(msg: "someMessage")

suite "Socket Server/Client RPC":
  var srv = newRpcSocketServer(["localhost:8545"])
  var client = newRpcSocketClient()

  srv.setupServer()
  srv.start()
  waitFor client.connect("localhost", Port(8545))

  test "Successful RPC call":
    let r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.getStr == "Hello abc data: [1, 2, 3, 4]"

  test "Missing params":
    expect(CatchableError):
      discard waitFor client.call("myProc", %[%"abc"])

  test "Error RPC call":
    expect(CatchableError): # The error type wont be translated
      discard waitFor client.call("myError", %[%"abc", %[1, 2, 3, 4]])

  srv.stop()
  waitFor srv.closeWait()
