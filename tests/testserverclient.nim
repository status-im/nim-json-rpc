import  ../ rpcclient, ../ rpcserver
import unittest, asyncdispatch, json, tables
from os import getCurrentDir, DirSep
from strutils import rsplit

# TODO: dummy implementations of RPC calls handled in async fashion.
# TODO: check required json parameters like version are being raised
var srv = sharedRpcServer()
srv.address = "localhost"
srv.port = Port(8545)

import stint, ethtypes, ethprocs

# generate all client ethereum rpc calls
createRpcSigs(currentSourcePath.rsplit(DirSep, 1)[0] & DirSep & "ethcallsigs.nim")

srv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)

asyncCheck srv.serve

suite "RPC":
  proc main {.async.} =
    var client = newRpcClient()
    await client.connect("localhost", Port(8545))

    test "Version":
      var response = waitFor client.web3_clientVersion()
      check response == "Nimbus-RPC-Test"
    test "SHA3":
      var response = waitFor client.web3_sha3("0x68656c6c6f20776f726c64")
      check response == "0x47173285A8D7341E5E972FC677286384F802F8EF42A5EC5F03BBFA254CB01FAD"
    test "Custom RPC":
      # Custom async RPC call
      var response = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
      check response.result.getStr == "Hello abc data: [1, 2, 3, 4]"

  waitFor main()  # TODO: When an error occurs during a test, stop the server
  