#[
  This module uses debug versions of the rpc components that
  allow unchecked and unformatted calls.
]#

import unittest, debugclient, ../rpcstreamservers
import strformat, chronicles

var server = newRpcStreamServer("localhost", 8547.Port)
var client = newRpcClient()

server.start()
waitFor client.connect("localhost", Port(8547))

server.rpc("rpc") do(a: int, b: int):
  result = %(&"a: {a}, b: {b}")

proc testMissingRpc: Future[Response] {.async.} =
  var fut = client.call("phantomRpc", %[])
  result = await fut

proc testInvalidJsonVer: Future[Response] {.async.} =
  let json =
    $ %{"jsonrpc": %"3.99", "method": %"rpc", "params": %[],
      "id": % $client.nextId} & "\c\l"
  var fut = client.rawCall("rpc", json)
  result = await fut

proc testMalformed: Future[Response] {.async.} =
  let malformedJson = "{field: 2, \"field: 3}"
  var fut = client.rawCall("rpc", malformedJson)
  await fut or sleepAsync(1000)
  if fut.finished: result = fut.read()
  else: result = (true, %"Timeout")

suite "RPC Errors":
  # Note: We don't expect a exceptions for most of the tests,
  # because the server should respond with the error in json
  test "Missing RPC":
    let res = waitFor testMissingRpc()
    check res.error == true and
      res.result["message"] == %"Method not found" and
      res.result["data"] == %"phantomRpc is not a registered method."

  test "Incorrect json version":
    let res = waitFor testInvalidJsonVer()
    check res.error == true and res.result["message"] == %"JSON 2.0 required"

  test "Malformed json":
    # TODO: We time out here because the server won't be able to
    # find an id to return to us, so we cannot complete the future.
    let res = waitFor testMalformed()
    check res.error == true and res.result == %"Timeout"
  
