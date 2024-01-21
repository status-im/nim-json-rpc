# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2, tables,
  stint, chronicles,
  ../json_rpc/[rpcclient, rpcserver],
  ./private/helpers,
  ./private/ethtypes,
  ./private/ethprocs,
  ./private/stintjson

from os import getCurrentDir, DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

var
  server = newRpcSocketServer("127.0.0.1", Port(0))
  client = newRpcSocketClient()

## Generate Ethereum server RPCs
server.addEthRpcs()

## Generate client convenience marshalling wrappers from forward declarations
createRpcSigs(RpcSocketClient, sourceDir & "/private/ethcallsigs.nim")

func rpcDynamicName(name: string): string =
  "rpc." & name

## Create custom RPC with StUint input parameter
server.rpc(rpcDynamicName "uint256Param") do(i: UInt256):
  let r = i + 1.stuint(256)
  return %r

## Create custom RPC with StUInt return parameter
server.rpc(rpcDynamicName "testReturnUint256") do() -> UInt256:
  let r: UInt256 = "0x1234567890abcdef".parse(UInt256, 16)
  return r

proc testLocalCalls: Future[seq[JsonString]] {.async.} =
  ## Call RPCs created with `rpc` locally.
  ## This simply demonstrates async calls of the procs generated by the `rpc` macro.
  let
    uint256Param =  server.executeMethod("rpc.uint256Param", %[%"0x1234567890"])
    returnUint256 = server.executeMethod("rpc.testReturnUint256", %[])

  await noCancel(allFutures(uint256Param, returnUint256))
  var pending: seq[JsonString]
  pending.add uint256Param.read()
  pending.add returnUint256.read()
  return pending

proc testRemoteUInt256: Future[seq[JsonString]] {.async.} =
  ## Call function remotely on server, testing `stint` types
  let
    uint256Param =  client.call("rpc.uint256Param", %[%"0x1234567890"])
    returnUint256 = client.call("rpc.testReturnUint256", %[])

  await noCancel(allFutures(uint256Param, returnUint256))
  var pending: seq[JsonString]
  pending.add uint256Param.read()
  pending.add returnUint256.read()
  return pending

proc testSigCalls: Future[seq[string]] {.async.} =
  ## Remote call using proc generated from signatures in `ethcallsigs.nim`
  let
    version = client.web3_clientVersion()
    sha3 = client.web3_sha3("0x68656c6c6f20776f726c64")

  await noCancel(allFutures(version, sha3))
  var pending: seq[string]
  pending.add version.read()
  pending.add sha3.read()
  return pending

server.start()
waitFor client.connect(server.localAddress()[0])


suite "Local calls":
  let localResults = testLocalCalls().waitFor
  test "UInt256 param local":
    check localResults[0] == %"0x1234567891"
  test "Return UInt256 local":
    check localResults[1] == %"0x1234567890abcdef"

suite "Remote calls":
  let remoteResults = testRemoteUInt256().waitFor
  test "UInt256 param":
    check remoteResults[0] == %"0x1234567891"
  test "Return UInt256":
    check remoteResults[1] == %"0x1234567890abcdef"

suite "Generated from signatures":
  let sigResults = testSigCalls().waitFor
  test "Version":
    check sigResults[0] == "Nimbus-RPC-Test"
  test "SHA3":
    check sigResults[1] == "0x47173285A8D7341E5E972FC677286384F802F8EF42A5EC5F03BBFA254CB01FAD"

server.stop()
waitFor server.closeWait()
