#[
  This module uses debug versions of the rpc components that
  allow unchecked and unformatted calls.
]#

import unittest, debugclient, ../rpcserver
import strformat, chronicles

var server = newRpcServer("localhost", 8547.Port)
var client = newRpcClient()

server.start()
waitFor client.connect("localhost", Port(8547))

server.rpc("rpc") do(a: int, b: int):
  result = %(&"a: {a}, b: {b}")

proc testMalformed: Future[Response] =
  let malformedJson = "{field: 2, \"field: 3}\n"
  result = client.rawCall("rpc", malformedJson)

proc testMissingRpc: Future[Response] =
  result = client.call("phantomRpc", %[])

suite "RPC Errors":
  test "Malformed json":
    expect ValueError:
      let res = waitFor testMalformed()
  test "Missing RPC":
    let res = waitFor testMissingRpc()
    echo ">>", res
echo "Error tests completed"
