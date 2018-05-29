import  ../ rpcclient, ../ rpcserver
import unittest, asyncdispatch, json

var srv = newRpcServer()
srv.address = "localhost"
srv.port = Port(8545)

srv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)

asyncCheck srv.serve

suite "Server/Client RPC":
  proc main {.async.} =
    var client = newRpcClient()
    await client.connect("localhost", Port(8545))

    test "Custom RPC":
      # Custom async RPC call
      var response = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
      check response.result.getStr == "Hello abc data: [1, 2, 3, 4]"

  # TODO: When an error occurs during a test, stop the server
  asyncCheck main()
  