import unittest2
import ../json_rpc/[rpcserver, rpcclient]

const TestsCount = 100

proc simpleTest(address: string, port: Port): Future[bool] {.async.} =
  var client = newRpcHttpClient()
  await client.connect(address, port, secure = false)
  var r = await client.call("noParamsProc", %[])
  if r.getStr == "Hello world":
    result = true

proc continuousTest(address: string, port: Port): Future[int] {.async.} =
  var client = newRpcHttpClient()
  result = 0
  for i in 0..<TestsCount:
    await client.connect(address, port, secure = false)
    var r = await client.call("myProc", %[%"abc", %[1, 2, 3, i]])
    if r.getStr == "Hello abc data: [1, 2, 3, " & $i & "]":
      result += 1
    await client.close()

proc invalidTest(address: string, port: Port): Future[bool] {.async.} =
  var client = newRpcHttpClient()
  await client.connect(address, port, secure = false)
  var invalidA, invalidB: bool
  try:
    var r = await client.call("invalidProcA", %[])
    discard r
  except ValueError:
    invalidA = true
  try:
    var r = await client.call("invalidProcB", %[1, 2, 3])
    discard r
  except ValueError:
    invalidB = true
  if invalidA and invalidB:
    result = true

var httpsrv = newRpcHttpServer(["localhost:8545"])

# Create RPC on server
httpsrv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)
httpsrv.rpc("noParamsProc") do():
  result = %("Hello world")

httpsrv.start()

suite "JSON-RPC test suite":
  test "Simple RPC call":
    check waitFor(simpleTest("localhost", Port(8545))) == true
  test "Continuous RPC calls (" & $TestsCount & " messages)":
    check waitFor(continuousTest("localhost", Port(8545))) == TestsCount
  test "Invalid RPC calls":
    check waitFor(invalidTest("localhost", Port(8545))) == true

waitFor httpsrv.stop()
waitFor httpsrv.closeWait()
