import unittest, json, chronicles, unittest
import ../rpchttpservers

var srv = newRpcHttpServer(["localhost:8545"])
var client = newRpcHttpClient()

# Create RPC on server
srv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)

srv.start()
waitFor client.httpConnect("localhost", Port(8545))

suite "HTTP RPC transport":
  test "Call":
    var r = waitFor client.httpcall("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.error == false and r.result == %"Hello abc data: [1, 2, 3, 4]"

srv.stop() 
srv.close()
