import unittest, json, chronicles
import  ../rpcclient, ../rpcsocket

var srv = newRpcSocketServer(["localhost:8545"])
var client = newRpcStreamClient()

# Create RPC on server
srv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)

srv.start()
waitFor client.connect("localhost", Port(8545))

# TODO: When an error occurs during a test, stop the server
suite "Server/Client RPC":
  test "Custom RPC":
    var r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.result.getStr == "Hello abc data: [1, 2, 3, 4]"

srv.stop()
srv.close()
