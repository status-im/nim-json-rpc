# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos/unittest2/asynctests, ../json_rpc/rpcchannels, ./private/helpers

# Create RPC on server
proc setupServer*(srv: RpcServer) =
  srv.rpc("myProc") do(input: string, data: array[0 .. 3, int]):
    return %("Hello " & input & " data: " & $data)

proc serverThread(chan: RpcChannelPtrs) {.thread.} =
  var srv = RpcChannelServer.new(chan)
  setupServer(srv)
  srv.start()
  waitFor sleepAsync(1.seconds)
  waitFor srv.closeWait()

suite "Thread channel RPC":
  asyncTest "Successful RPC call":
    var chan: RpcChannel
    var ptrs = chan.open().expect("")
    var server: Thread[RpcChannelPtrs]
    var client = newRpcChannelClient(ptrs)

    createThread(server, serverThread, ptrs)
    waitFor client.connect()
    let r = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
    check r.string == "\"Hello abc data: [1, 2, 3, 4]\""
