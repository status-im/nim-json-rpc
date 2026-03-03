# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ../json_rpc/rpcclient
import ../json_rpc/rpcserver
import
  chronos/unittest2/asynctests,
  stew/byteutils

createCborFlavor CborFlavor,
  automaticObjectSerialization = false,
  automaticPrimitivesSerialization = false

CborFlavor.defaultSerialization string

proc setupServer*(srv: RpcServer) =
  srv.rpc(CborFlavor):
    proc myProcCtx1(s: string): string =
      #doAssert false
      return s

    proc serverErr(): string =
      raise (ref ValueError)(msg: "the error message")

    proc teaPot(): string =
      raise (ref ApplicationError)(
        code: 418, data: Opt.none(JsonString), msg: "I'm a teapot"
      )

createRpcSigsFromNim(RpcClient, CborFlavor):
  proc myProcCtx1(s: string): string
  proc serverErr(): string
  proc teaPot(): string

template callTests(client: untyped) =
  test "Successful RPC call":
    let r = waitFor client.myProcCtx1("abc")
    check r.string == "abc"

  test "Server Error RPC call":
    try:
      discard waitFor client.serverErr()
      fail()
    except JsonRpcError as err:
      let data = string.fromBytes CrpcSys.encode("the error message")
      check CrpcSys.decode(err.msg, ResponseError) ==
        ResponseError(
          code: -32000,
          message: "`serverErr` raised an exception",
          data: Opt.some(data.JsonString)
        )

  test "Application Error RPC call":
    try:
      discard waitFor client.teaPot()
      fail()
    except JsonRpcError as err:
      check CrpcSys.decode(err.msg, ResponseError) ==
        ResponseError(code: 418, message: "I'm a teapot")

suite "Socket Server/Client RPC/lengthHeaderBE32":
  setup:
    const framing = Framing.lengthHeaderBE32()
    const format = RpcFormat.Cbor
    var srv = newRpcSocketServer(["127.0.0.1:0"], framing = framing, format = format)
    var client = newRpcSocketClient(framing = framing, format = format)
    doAssert client.format == RpcFormat.Cbor

    srv.setupServer()
    srv.start()
    waitFor client.connect(srv.localAddress()[0])

  teardown:
    waitFor client.close()
    srv.stop()
    waitFor srv.closeWait()

  callTests(client)
