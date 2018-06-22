import unittest, json, chronicles
import  ../rpcclient, ../rpchttpservers

var srv = newRpcHttpServer(["localhost:8545"])
var client = newRpcStreamClient()

# Create RPC on server
srv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)

srv.start()
waitFor client.connect("localhost", Port(8545))

var r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
echo r

srv.stop()
srv.close()
echo "done"