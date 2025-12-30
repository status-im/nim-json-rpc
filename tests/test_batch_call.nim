# json-rpc
# Copyright (c) 2024 Status Research & Development GmbH
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

createRpcSigsFromNim(RpcClient):
  proc get_banana(id: int): bool
  proc get_apple(id: string): string
  proc get_except(): string

proc setupServer(server: RpcServer) =
  server.rpc("get_banana") do(id: int) -> bool:
    await sleepAsync(10.milliseconds)
    return id == 13

  server.rpc("get_apple") do(id: string) -> string:
    return "apple: " & id

  server.rpc("get_except") do() -> string:
    raise newException(ValueError, "get_except error")

suite "Socket batch call":
  var srv = newRpcSocketServer(["127.0.0.1:0"])
  var client = newRpcSocketClient()

  srv.setupServer()
  srv.start()
  waitFor client.connect(srv.localAddress()[0])

  test "batch call basic":
    let batch = client.prepareBatch()

    batch.get_banana(11)
    batch.get_apple("green")
    batch.get_except()

    let res = waitFor batch.send()
    check res.isOk
    if res.isErr:
      debugEcho res.error
      break

    let r = res.get
    check r[0].error.isNone
    check r[0].result.string == "false"

    check r[1].error.isNone
    check r[1].result.string == "\"apple: green\""

    check r[2].error.isSome
    check r[2].error.get == """{"code":-32000,"message":"`get_except` raised an exception","data":"get_except error"}"""
    check r[2].result.string.len == 0

  test "rpc call after batch call":
    let res = waitFor client.get_banana(13)
    check res == true

  srv.stop()
  waitFor srv.closeWait()

suite "HTTP batch call":
  var srv = newRpcHttpServer(["127.0.0.1:0"])
  var client = newRpcHttpClient()

  srv.setupServer()
  srv.start()
  waitFor client.connect("http://" & $srv.localAddress()[0])

  test "batch call basic":
    let batch = client.prepareBatch()

    batch.get_banana(11)
    batch.get_apple("green")
    batch.get_except()

    let res = waitFor batch.send()
    check res.isOk
    if res.isErr:
      debugEcho res.error
      break

    let r = res.get
    check r[0].error.isNone
    check r[0].result.string == "false"

    check r[1].error.isNone
    check r[1].result.string == "\"apple: green\""

    check r[2].error.isSome
    check r[2].error.get == """{"code":-32000,"message":"`get_except` raised an exception","data":"get_except error"}"""
    check r[2].result.string.len == 0

  test "rpc call after batch call":
    let res = waitFor client.get_banana(13)
    check res == true

  waitFor srv.stop()
  waitFor srv.closeWait()

suite "Websocket batch call":
  var srv = newRpcWebSocketServer("127.0.0.1", Port(0))
  var client = newRpcWebSocketClient()

  srv.setupServer()
  srv.start()
  waitFor client.connect("ws://" & $srv.localAddress())

  test "batch call basic":
    let batch = client.prepareBatch()

    batch.get_banana(11)
    batch.get_apple("green")
    batch.get_except()

    let res = waitFor batch.send()
    check res.isOk
    if res.isErr:
      debugEcho res.error
      break

    let r = res.get
    check r[0].error.isNone
    check r[0].result.string == "false"

    check r[1].error.isNone
    check r[1].result.string == "\"apple: green\""

    check r[2].error.isSome
    check r[2].error.get == """{"code":-32000,"message":"`get_except` raised an exception","data":"get_except error"}"""
    check r[2].result.string.len == 0

  test "rpc call after batch call":
    let res = waitFor client.get_banana(13)
    check res == true

  srv.stop()
  waitFor srv.closeWait()
