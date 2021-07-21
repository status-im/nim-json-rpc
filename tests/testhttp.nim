import unittest, json, strutils
import httputils
import ../json_rpc/[rpcserver, rpcclient]

const TestsCount = 100

proc continuousTest(address: string, port: Port): Future[int] {.async.} =
  var client = newRpcHttpClient()
  result = 0
  for i in 0..<TestsCount:
    await client.connect(address, port)
    var r = await client.call("myProc", %[%"abc", %[1, 2, 3, i]])
    if r.getStr == "Hello abc data: [1, 2, 3, " & $i & "]":
      result += 1
    await client.close()

var httpsrv = newRpcHttpServer(["localhost:8545"])

# Create RPC on server
httpsrv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)
httpsrv.rpc("noParamsProc") do():
  result = %("Hello world")

httpsrv.start()

suite "JSON-RPC test suite":
  test "Continuous RPC calls (" & $TestsCount & " messages)":
    check waitFor(continuousTest("localhost", Port(8545))) == TestsCount

waitFor httpsrv.stop()
waitFor httpsrv.closeWait()
