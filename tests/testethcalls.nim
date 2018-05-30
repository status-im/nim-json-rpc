import ../ rpcclient, ../ rpcserver
import unittest, asyncdispatch, json, tables

from os import getCurrentDir, DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

var srv = sharedRpcServer()
srv.address = "localhost"
srv.port = Port(8546)

# importing ethprocs creates the server rpc calls
import stint, ethtypes, ethprocs, stintJsonConverters
# generate all client ethereum rpc calls
createRpcSigs(sourceDir & DirSep & "ethcallsigs.nim")

srv.rpc("rpc.uint256param") do(i: UInt256):
  let r = i + 1.stUint(256)
  result = %r
  
srv.rpc("rpc.testreturnuint256") do() -> UInt256:
  let r: UInt256 = "0x1234567890abcdef".parse(UInt256, 16)
  return r

asyncCheck srv.serve

suite "Ethereum RPCs":
  proc main {.async.} =
    var client = newRpcClient()
    await client.connect("localhost", Port(8546))

    test "UInt256 param":
      let r = waitFor rpcUInt256Param(%[%"0x1234567890"])
      check r == %"0x1234567891"

    test "Return UInt256":
      let r = waitFor rpcTestReturnUInt256(%[])
      check r == %"0x1234567890abcdef"

    test "Version":
      var
        response = waitFor client.web3_clientVersion()
      check response == "Nimbus-RPC-Test"
    test "SHA3":
      var response = waitFor client.web3_sha3("0x68656c6c6f20776f726c64")
      check response == "0x47173285A8D7341E5E972FC677286384F802F8EF42A5EC5F03BBFA254CB01FAD"

  waitFor main()
