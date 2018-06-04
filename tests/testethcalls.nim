import unittest, json, tables
import asyncdispatch2
import ../rpcclient, ../rpcserver

from os import getCurrentDir, DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

# importing ethprocs creates the server rpc calls
import stint, ethtypes, ethprocs, stintjson
# generate all client ethereum rpc calls
createRpcSigs(sourceDir & DirSep & "ethcallsigs.nim")

rpc("rpc.uint256param") do(i: UInt256):
  let r = i + 1.stUint(256)
  result = %r

rpc("rpc.testreturnuint256") do() -> UInt256:
  let r: UInt256 = "0x1234567890abcdef".parse(UInt256, 16)
  return r

proc test1(): Future[bool] {.async.} =
  var client = newRpcClient()
  await client.connect(initTAddress("127.0.0.1:8546"))
  let r = await rpcUInt256Param(%[%"0x1234567890"])
  result = (r == %"0x1234567891")
  client.close()

proc test2(): Future[bool] {.async.} =
  var client = newRpcClient()
  await client.connect(initTAddress("127.0.0.1:8546"))
  let r = await rpcTestReturnUInt256(%[])
  result = (r == %"0x1234567890abcdef")
  client.close()

proc test3(): Future[bool] {.async.} =
  var client = newRpcClient()
  await client.connect(initTAddress("127.0.0.1:8546"))
  let r = await client.web3_clientVersion()
  result = (r == "Nimbus-RPC-Test")
  client.close()

proc test4(): Future[bool] {.async.} =
  var e = "0x47173285A8D7341E5E972FC677286384F802F8EF42A5EC5F03BBFA254CB01FAD"
  var client = newRpcClient()
  await client.connect(initTAddress("127.0.0.1:8546"))
  let r = await client.web3_sha3("0x68656c6c6f20776f726c64")
  result = (r == e)
  client.close()

suite "Ethereum RPCs":
  var srv = newRpcServer(initTAddress("127.0.0.1:8546"))
  srv.register("rpc.uint256param", "rpc.testreturnuint256",
               "web3_clientVersion", "web3_sha3")
  srv.start()
  test "UInt256 param":
    check waitFor(test1()) == true
  test "Return UInt256":
    check waitFor(test2()) == true
  test "Version":
    check waitFor(test3()) == true
  test "SHA3":
    check waitFor(test4()) == true

  srv.stop()
  srv.close()
