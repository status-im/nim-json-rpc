import unittest, json, strutils
import httputils, chronicles
import ../json_rpc/[rpcserver, rpcclient]

const
  TestsCount = 100
  BufferSize = 8192
  BigHeaderSize = 8 * 1024 + 1
  BigBodySize = 1024 * 1024 + 1
  HeadersMark = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

  Requests = [
    "GET / HTTP/1.1\r\n" &
      "Host: status.im\r\n" &
      "Content-Length: 71\r\n" &
      "Content-Type: text/html\r\n" &
      "Connection: close\r\n" &
      "\r\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"myProc\",\"params\":[\"abc\", [1, 2, 3]],\"id\":67}",
    "BADHEADER HTTP/1.1\r\n\r\n",
    "GET / HTTP/1.1\r\n" &
      "Host: status.im\r\n" &
      "Content-Type: application/json\r\n" &
      "Connection: close\r\n" &
      "\r\n",
    "PUT / HTTP/1.1\r\n" &
      "Host: status.im\r\n" &
      "Content-Length: 71\r\n" &
      "Content-Type: text/html\r\n" &
      "Connection: close\r\n" &
      "\r\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"myProc\",\"params\":[\"abc\", [1, 2, 3]],\"id\":67}",
    "DELETE / HTTP/1.1\r\n" &
      "Host: status.im\r\n" &
      "Content-Length: 71\r\n" &
      "Content-Type: text/html\r\n" &
      "Connection: close\r\n" &
      "\r\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"myProc\",\"params\":[\"abc\", [1, 2, 3]],\"id\":67}",
    "GET / HTTP/0.9\r\n" &
      "Host: status.im\r\n" &
      "Content-Length: 71\r\n" &
      "Content-Type: application/json\r\n" &
      "\r\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"myProc\",\"params\":[\"abc\", [1, 2, 3]],\"id\":67}",
    "GET / HTTP/1.0\r\n" &
      "Host: status.im\r\n" &
      "Content-Length: 71\r\n" &
      "Content-Type: application/json\r\n" &
      "\r\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"myProc\",\"params\":[\"abc\", [1, 2, 3]],\"id\":67}",
    "GET / HTTP/1.1\r\n" &
      "Host: status.im\r\n" &
      "Content-Length: 71\r\n" &
      "Content-Type: application/json\r\n" &
      "Connection: close\r\n" &
      "\r\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"myProc\",\"params\":[\"abc\", [1, 2, 3]],\"id\":67}",
    "GET / HTTP/1.1\r\n" &
      "Host: status.im\r\n" &
      "Content-Length: 49\r\n" &
      "Content-Type: application/json\r\n" &
      "Connection: close\r\n" &
      "\r\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"noParamsProc\",\"id\":67}",
    "GET / HTTP/1.1\r\n" &
      "Host: status.im\r\n" &
      "Content-Length: 137438953472\r\n" &
      "Content-Type: application/json\r\n" &
      "Connection: close\r\n" &
      "\r\n" &
      "{128 gb Content-Length}",
  ]

proc continuousTest(address: string, port: Port): Future[int] {.async.} =
  var client = newRpcHttpClient()
  result = 0
  for i in 0..<TestsCount:
    await client.connect(address, port)
    var r = await client.call("myProc", %[%"abc", %[1, 2, 3, i]])
    if r.getStr == "Hello abc data: [1, 2, 3, " & $i & "]":
      result += 1
    await client.close()

proc customMessage(address: TransportAddress,
                   data: string,
                   expect: int): Future[bool] {.async.} =
  var buffer = newSeq[byte](BufferSize)
  var header: HttpResponseHeader
  var transp = await connect(address)
  defer: transp.close()

  let wres = await transp.write(data)
  doAssert(wres == len(data))
  let rres = await transp.readUntil(addr buffer[0], BufferSize, HeadersMark)
  doAssert(rres > 0)
  buffer.setLen(rres)
  header = parseResponse(buffer)
  doAssert(header.success())
  return header.code == expect

proc headerTest(address: string, port: Port): Future[bool] {.async.} =
  var a = resolveTAddress(address, port)
  var header = "GET / HTTP/1.1\r\n"
  var i = 0
  while len(header) <= BigHeaderSize:
    header.add("Field" & $i & ": " & $i & "\r\n")
    inc(i)
  header.add("Content-Length: 71\r\n")
  header.add("Content-Type: application/json\r\n")
  header.add("Connection: close\r\n\r\n")
  header.add("{\"jsonrpc\":\"2.0\",\"method\":\"myProc\",\"params\":[\"abc\", [1, 2, 3]],\"id\":67}")
  return await customMessage(a[0], header, 431)

proc bodyTest(address: string, port: Port): Future[bool] {.async.} =
  var body = repeat('B', BigBodySize)
  var a = resolveTAddress(address, port)
  var header = "GET / HTTP/1.1\r\n"
  header.add("Content-Length: " & $len(body) & "\r\n")
  header.add("Content-Type: application/json\r\n")
  header.add("Connection: close\r\n\r\n")
  header.add(body)
  return await customMessage(a[0], header, 413)

proc disconTest(address: string, port: Port,
                number: int, expect: int): Future[bool] {.async.} =
  var a = resolveTAddress(address, port)
  var buffer = newSeq[byte](BufferSize)
  var header: HttpResponseHeader
  var transp = await connect(a[0])
  defer: transp.close()

  let data = Requests[number]
  let wres = await transp.write(data)
  doAssert(wres == len(data))
  let rres = await transp.readUntil(addr buffer[0], BufferSize, HeadersMark)
  doAssert(rres > 0)
  buffer.setLen(rres)
  header = parseResponse(buffer)
  doAssert(header.success())
  if header.code != expect:
    return false

  let length = header.contentLength()
  doAssert(length > 0)
  buffer.setLen(length)
  await transp.readExactly(addr buffer[0], len(buffer))
  let left = await transp.read()
  return len(left) == 0 and transp.atEof()

proc simpleTest(address: string, port: Port,
                number: int, expect: int): Future[bool] {.async.} =
  var a = resolveTAddress(address, port)
  result = await customMessage(a[0], Requests[number], expect)

var httpsrv = newRpcHttpServer(["localhost:8545"])

# Create RPC on server
httpsrv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)
httpsrv.rpc("noParamsProc") do():
  result = %("Hello world")

httpsrv.start()

suite "HTTP Server/HTTP Client RPC test suite":
  test "Continuous RPC calls (" & $TestsCount & " messages)":
    check waitFor(continuousTest("localhost", Port(8545))) == TestsCount
  # test "Wrong [Content-Type] test":
  #   check waitFor(simpleTest("localhost", Port(8545), 0, 415)) == true
  test "Bad request header test":
    check waitFor(simpleTest("localhost", Port(8545), 1, 400)) == true
  test "Zero [Content-Length] test":
    check waitFor(simpleTest("localhost", Port(8545), 2, 200)) == true
  test "PUT/DELETE methods test":
    check:
      waitFor(simpleTest("localhost", Port(8545), 3, 200)) == true
      waitFor(simpleTest("localhost", Port(8545), 4, 200)) == true
  test "Oversized headers test":
    check waitFor(headerTest("localhost", Port(8545))) == true
  test "Oversized request test":
    check waitFor(bodyTest("localhost", Port(8545))) == true
  test "HTTP/0.9 and HTTP/1.0 client test":
    check:
      waitFor(disconTest("localhost", Port(8545), 5, 200)) == true
      waitFor(disconTest("localhost", Port(8545), 6, 200)) == true
  test "[Connection]: close test":
    check waitFor(disconTest("localhost", Port(8545), 7, 200)) == true
  test "Omitted params test":
    check waitFor(simpleTest("localhost", Port(8545), 8, 200)) == true
  test "Big Content-Length":
    check waitFor(simpleTest("localhost", Port(8545), 9, 413)) == true

waitFor httpsrv.stop()
waitFor httpsrv.closeWait()
