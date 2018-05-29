import  ../ rpcclient, ../ rpcserver
import unittest, asyncdispatch, json, tables

from os import getCurrentDir, DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

var srv = sharedRpcServer()
srv.address = "localhost"
srv.port = Port(8546)

# importing ethprocs creates the server rpc calls
import stint, ethtypes, ethprocs
# generate all client ethereum rpc calls
createRpcSigs(sourceDir & DirSep & "ethcallsigs.nim")

asyncCheck srv.serve

suite "Ethereum RPCs":
  proc main {.async.} =
    var client = newRpcClient()
    await client.connect("localhost", Port(8546))

    test "Version":
      var
        response = waitFor client.web3_clientVersion()
      check response == "Nimbus-RPC-Test"
    test "SHA3":
      var response = waitFor client.web3_sha3("0x68656c6c6f20776f726c64")
      check response == "0x47173285A8D7341E5E972FC677286384F802F8EF42A5EC5F03BBFA254CB01FAD"

  waitFor main()
