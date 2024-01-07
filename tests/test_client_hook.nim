# json-rpc
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2,
  ../json_rpc/rpcclient,
  ../json_rpc/rpcserver

createRpcSigsFromNim(RpcClient):
  proc get_Banana(id: int): int

proc installHandlers(s: RpcServer) =
  s.rpc("get_Banana") do(id: int) -> JsonString:
    if id == 99:
      return "123".JsonString
    elif id == 100:
      return "\"stop\"".JsonString
    else:
      return "\"error\"".JsonString

type
  Shadow = ref object
    something: int

proc setupClientHook(client: RpcClient): Shadow =
  var shadow = Shadow(something: 0)
  client.onProcessMessage = proc(client: RpcClient, line: string):
                                Result[bool, string] {.gcsafe, raises: [].} =

     try:
       let m = JrpcConv.decode(line, JsonNode)
       if m["result"].kind == JString:
           if m["result"].str == "stop":
             shadow.something = 123
             return ok(false)
           else:
             shadow.something = 77
             return err("not stop")

       return ok(true)
     except CatchableError as exc:
      return err(exc.msg)
  shadow

suite "test callsigs":
  var server = newRpcHttpServer(["127.0.0.1:0"])
  server.installHandlers()
  var client = newRpcHttpClient()
  let shadow = client.setupClientHook()

  server.start()
  waitFor client.connect("http://" & $server.localAddress()[0])

  test "client onProcessMessage hook":
    let res = waitFor client.get_Banana(99)
    check res == 123
    check shadow.something == 0

    expect JsonRpcError:
      let res2 = waitFor client.get_Banana(123)
      check res2 == 0
    check shadow.something == 77

    expect InvalidResponse:
      let res2 = waitFor client.get_Banana(100)
      check res2 == 0
    check shadow.something == 123

  waitFor server.stop()
  waitFor server.closeWait()
