# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## In-process test of the pipes server, over a pair of pipes.

import
  chronos/unittest2/asynctests,
  ../json_rpc/[rpcclient, rpcserver],
  ./private/helpers

suite "pipes server stop":
  # The server runs in-process over a pair of pipes, with a client attached to
  # the other ends.
  setup:
    let
      toServer = newPipe()
      toClient = newPipe()
      srv = newRpcPipesServer()
      client = newRpcPipesClient()
      slowStarted = newAsyncEvent()

    srv.rpc(JrpcConv):
      proc hello(name: string): string =
        "Hello " & name

      proc slow(ms: int): string {.async: (raises: [CancelledError]).} =
        slowStarted.fire()
        await sleepAsync(ms.milliseconds)
        "slow"

    srv.start(toServer.read, toClient.write)
    client.connect(toClient.read, toServer.write, "server")

  teardown:
    waitFor srv.closeWait()
    waitFor client.close()

  asyncTest "stop ends serve":
    let serving = srv.serve()
    check (await client.call("hello", %[%"x"])) == JsonString("\"Hello x\"")
    check srv.connections.len == 1

    await srv.stop()
    check await serving.withTimeout(5.seconds)
    check serving.completed()
    check srv.connections.len == 0

  asyncTest "cancelling serve stops the connection":
    let serving = srv.serve()
    check (await client.call("hello", %[%"x"])) == JsonString("\"Hello x\"")

    await serving.cancelAndWait()
    check serving.cancelled()
    check srv.connections.len == 0
    # The client sees the end of the stream
    check await client.loop.join().withTimeout(5.seconds)

  asyncTest "stop ends serve with a request in flight":
    let serving = srv.serve()
    let pending = client.call("slow", %[%10_000])
    check await slowStarted.wait().withTimeout(5.seconds)

    await srv.stop()
    check await serving.withTimeout(5.seconds)
    check serving.completed()
    check await pending.withTimeout(5.seconds)
    check pending.failed()

  asyncTest "serve reports a connection that fails on its own":
    let serving = srv.serve()
    discard await client.output.write("Content-Length: -5\r\n\r\nxxxxx")
    check await serving.withTimeout(5.seconds)
    check serving.failed()
    check serving.error of JsonRpcError

  asyncTest "stop closes the connection":
    discard await client.call("hello", %[%"x"])
    await srv.stop()
    # The client sees the end of the stream
    check await client.loop.join().withTimeout(5.seconds)
    expect(JsonRpcError):
      discard await client.call("hello", %[%"y"])

  asyncTest "stop aborts a request in flight":
    let pending = client.call("slow", %[%10_000])
    check await slowStarted.wait().withTimeout(5.seconds)
    await srv.stop()
    check await pending.withTimeout(5.seconds)
    check pending.failed()

  asyncTest "stop without serve":
    discard await client.call("hello", %[%"x"])
    await srv.stop()
    check srv.connections.len == 0
    check await client.loop.join().withTimeout(5.seconds)

  asyncTest "stop twice":
    await srv.stop()
    await srv.stop()
    check srv.connections.len == 0

suite "pipes server stop race":
  asyncTest "stop from a message handled while starting":
    # A message already waiting when the server starts is handled inside
    # `start`, before it has stored the loop
    let
      toServer = newPipe()
      toClient = newPipe()
      srv = newRpcPipesServer()
      clientOutput = toServer.write
      clientInput = toClient.read

    srv.rpc(JrpcConv):
      proc stopServer(): void =
        asyncSpawn srv.stop()

    const notification = """{"jsonrpc":"2.0","method":"stopServer","params":[]}"""
    discard await clientOutput.write(
      "Content-Length: " & $notification.len & "\r\n\r\n" & notification
    )
    srv.start(toServer.read, toClient.write)

    # The server closes its output
    check await clientInput.read().withTimeout(5.seconds)
    check srv.connections.len == 0

    await clientOutput.closeWait()
    await clientInput.closeWait()
    await srv.closeWait()

suite "pipes server stress":
  # Notification floods larger than the pipe buffer (64 KiB on Linux), so the
  # server has to wait for the client to drain the pipe.
  setup:
    const
      reqCount =
        when defined(release) or defined(danger):
          2048
        else:
          64
    let
      toServer = newPipe()
      toClient = newPipe()
      srv = newRpcPipesServer()
      floodSeen = newAsyncEvent()
    var
      clientRouter = new(RpcRouter)
      seen = 0
    clientRouter[] = RpcRouter.init()
    clientRouter[].rpc("flooded", JrpcConv) do(i: int, payload: string) -> void:
      inc seen
      if seen == reqCount:
        floodSeen.fire()

    srv.rpc(JrpcConv):
      proc hello(name: string): string =
        "Hello " & name

      proc flood(count: int, size: int): int {.async: (raises: [CancelledError]).} =
        # Notifications the client has not read yet fill the pipe to it
        let payload = block:
          var s = newString(size)
          for i in 0 ..< s.len:
            s[i] = 'x'
          s
        for i in 0 ..< count:
          await srv.notify(
            "flooded",
            RequestParamsTx(
              kind: rpPositional,
              positional: @[JsonString($i), JsonString($(%payload))]
            ),
          )
        count

    let client = newRpcPipesClient(router = clientRouter)
    srv.start(toServer.read, toClient.write)
    client.connect(toClient.read, toServer.write, "server")

  teardown:
    waitFor client.close()
    waitFor srv.closeWait()

  asyncTest "the server floods the client with notifications while it keeps requesting":
    let flooding = client.call("flood", %[%reqCount, %2048])
    for i in 0 ..< 64:
      check (await client.call("hello", %[%($i)])) == JsonString("\"Hello " & $i & "\"")
    check await flooding.withTimeout(30.seconds)
    check await floodSeen.wait().withTimeout(30.seconds)
    check seen == reqCount
