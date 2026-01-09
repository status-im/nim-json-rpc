# json-rpc
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2,
  ../json_rpc/rpcclient,
  ../json_rpc/rpcserver,
  ./private/helpers

from os import getCurrentDir, DirSep, AltSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]

type
  Variant = int | bool | string
  RefObject = ref object
    name: string

RefObject.useDefaultSerializationIn JrpcConv

createRpcSigs(RpcClient, sourceDir & "/private/file_callsigs.nim")

createSingleRpcSig(RpcClient, "bottle"):
  proc get_Bottle(id: int): bool

createSingleRpcSig(RpcClient, "mouse"):
  proc getVariant(id: Variant): bool

createRpcSigsFromNim(RpcClient):
  proc get_Banana(id: int): bool
  proc get_Combo(id, index: int, name: string): bool
  proc get_Name(id: int): string
  proc getJsonString(name: string): JsonString
  proc getVariant(id: Variant): bool
  proc getRefObject(shouldNull: bool): RefObject

proc installHandlers(s: RpcServer) =
  s.rpc("shh_uninstallFilter") do(id: int) -> bool:
    if id == 123:
      return true
    else:
      return false

  s.rpc("get_Bottle") do(id: int) -> bool:
    if id == 456:
      return true
    else:
      return false

  s.rpc("get_Banana") do(id: int) -> bool:
    if id == 789:
      return true
    else:
      return false

  s.rpc("get_Combo") do(id, index: int, name: string) -> bool:
    if index == 77 and name == "banana":
      return true
    return false

  s.rpc("get_Name") do(id: int) -> string:
    if id == 99:
      return "king kong"
    return "godzilla"

  s.rpc("getJsonString") do(name: string) -> JsonString:
    if name == "me":
      return "true".JsonString
    return "123".JsonString

  s.rpc("getVariant") do(id: string) -> bool:
    if id == "33":
      return true
    return false

  s.rpc("getFilter") do(id: string) -> string:
    if id == "cow":
      return "moo"
    return "meow"

  s.rpc("getRefObject") do(shouldNull: bool) -> Refobject:
    if shouldNull: return nil
    return RefObject(name: "meow")

suite "test callsigs":
  var server = newRpcSocketServer(["127.0.0.1:0"])
  server.installHandlers()
  var client = newRpcSocketClient()

  server.start()
  waitFor client.connect(server.localAddress()[0])

  test "callsigs from file":
    let res = waitFor client.shh_uninstallFilter(123)
    check res == true

    let res2 = waitFor client.getFilter("cow")
    check res2 == "moo"

  test "callsigs alias":
    let res = waitFor client.bottle(456)
    check res == true

    let res2 = waitFor client.mouse("33")
    check res2 == true

    let res3 = waitFor client.mouse("55")
    check res3 == false

    expect JsonRpcError:
      let res4 = waitFor client.mouse(33)
      check res4 == true

  test "callsigs from nim":
    let res = waitFor client.get_Banana(789)
    check res == true

    let res2 = waitFor client.get_Name(99)
    check res2 == "king kong"

    let res3 = waitFor client.get_Combo(0, 77, "banana")
    check res3 == true

    let res4 = waitFor client.getJsonString("me")
    check res4 == "true".JsonString

    let res5 = waitFor client.getVariant("33")
    check res5 == true

    let res6 = waitFor client.getVariant("55")
    check res6 == false

    expect JsonRpcError:
      let res4 = waitFor client.getVariant(33)
      check res4 == true

  test "Handle null return value correctly":
    let res = waitFor client.getRefObject(true)
    check res.isNil

    let res2 = waitFor client.getRefObject(false)
    check res2.isNil.not
    check res2.name == "meow"

  server.stop()
  waitFor server.closeWait()

type
  DisString = distinct string

createJsonFlavor JrpcFlavor,
  automaticPrimitivesSerialization = true

var registry {.threadvar.}: seq[string]

proc readValue(reader: var JrpcFlavor.Reader, value: var DisString) =
  value = reader.readValue(string).DisString
  registry.add value.string

proc writeValue(writer: var JrpcFlavor.Writer, value: DisString) =
  writer.writeValue value.string
  registry.add value.string

createRpcSigs(RpcClient, sourceDir & "/private/file_callsigs_flavor.nim", JrpcFlavor)

createSingleRpcSig(RpcClient, "aliasFlavor", JrpcFlavor):
  proc getAliasFlavor(s: DisString): DisString

createRpcSigsFromNim(RpcClient, JrpcFlavor):
  proc getNimFlavor(s: DisString): DisString

proc installFlavorHandlers(s: RpcServer) =
  s.rpc("getFileFlavor", JrpcFlavor) do(s: DisString) -> DisString:
    return DisString("ret " & s.string)

  s.rpc("getAliasFlavor", JrpcFlavor) do(s: DisString) -> DisString:
    return DisString("ret " & s.string)

  s.rpc("getNimFlavor", JrpcFlavor) do(s: DisString) -> DisString:
    return DisString("ret " & s.string)

suite "test callsigs with flavors":
  var server = newRpcSocketServer(["127.0.0.1:0"])
  server.installFlavorHandlers()
  var client = newRpcSocketClient()

  server.start()
  waitFor client.connect(server.localAddress()[0])

  setup:
    registry.setLen 0

  test "callsigs from file with flavor":
    let res = waitFor client.getFileFlavor("file".DisString)
    check res.string == "ret file"
    check registry == @["file", "file", "ret file", "ret file"]

  test "callsigs alias with flavor":
    let res = waitFor client.aliasFlavor("alias".DisString)
    check res.string == "ret alias"
    check registry == @["alias", "alias", "ret alias", "ret alias"]

  test "callsigs from nim with flavor":
    let res = waitFor client.getNimFlavor("nim".DisString)
    check res.string == "ret nim"
    check registry == @["nim", "nim", "ret nim", "ret nim"]

  server.stop()
  waitFor server.closeWait()
