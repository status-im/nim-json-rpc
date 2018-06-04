import json, unittest
import asyncdispatch2
import  ../rpcclient, ../rpcserver

var srv = newRpcServer(initTAddress("127.0.0.1:8545"))

srv.registerRpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)

srv.start()

proc test1(): Future[bool] {.async.} =
  var client = newRpcClient()
  await client.connect(initTAddress("127.0.0.1:8545"))
  var resp = await client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
  result = (resp.result.getStr == "Hello abc data: [1, 2, 3, 4]")
  client.close()

proc test2(): Future[bool] {.async.} =
  var client = newRpcClient()
  await client.connect(initTAddress("127.0.0.1:8545"))
  var resp = await client.call("myProc2", %[%"abc", %[1, 2, 3, 4]])
  result = (resp.error == true)
  client.close()

when isMainModule:
  suite "Server/Client RPC":
    test "Custom successful RPC call":
      check waitFor(test1()) == true
    test "Custom `Method not found` RPC call":
      check waitFor(test2()) == true

srv.stop()
srv.close()
