# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## End-to-end test of the stdio transport, using two real processes: the test
## binary re-executes itself with `--rpc-stdio-server`, and that child serves
## JSON-RPC over its own standard input/output while the parent drives it with
## an `RpcStdioClient`.

proc checkChronicles(): bool =
  const chronicles_sinks {.strdefine.} = ""
  chronicles_sinks == "textlines[stderr]"

when not checkChronicles():
  {.error: "required `-d:chronicles_sinks=textlines[stderr]` to avoid sending chronicles output to stdio".}

import
  std/[json, os, strutils],
  chronos/unittest2/asynctests,
  ../json_rpc/[rpcclient, rpcserver],
  ../json_rpc/clients/stdioclient,
  ../json_rpc/servers/stdioserver,
  ./private/helpers

const ServerArg = "--rpc-stdio-server"

proc framingByName(name: string): StdioFraming =
  case name
  of "be32": StdioFraming.lengthHeaderBE32()
  else: StdioFraming.httpHeader()

# ---------------------------------------------------------------------------
# The child: a JSON-RPC server whose transport is its own stdin/stdout
# ---------------------------------------------------------------------------

var childServer: RpcStdioServer

proc askClientAsync(conn: RpcConnection, question: string) {.async: (raises: []).} =
  ## Ask the peer something, then tell it what came back.
  try:
    let answer = await conn.call("client/answer", %[%question])
    await conn.notify("client/answered", default(RequestParamsTx))
    doAssert answer.string == "\"re: " & question & "\"", answer.string
  except CatchableError:
    discard

proc runChildServer(framingName: string) {.raises: [].} =
  let srv = newRpcStdioServer(framing = framingByName(framingName))
  childServer = srv

  srv.rpc("hello") do(name: string):
    %("Hello " & name)

  srv.rpc("bigPayload") do(size: int):
    %repeat('x', size)

  srv.rpc("slow") do(ms: int, tag: string):
    await sleepAsync(ms.milliseconds)
    %tag

  srv.rpc("boom") do():
    raise (ref ValueError)(msg: "boom")

  srv.rpc("askClient") do(question: string):
    # Server -> client request over the same connection: this is what makes the
    # transport bidirectional rather than a request/response pipe.
    #
    # It is dispatched rather than awaited here because json_rpc's read loop
    # handles one message at a time (the socket transport behaves the same
    # way): awaiting the peer's answer inside a handler would deadlock, since
    # that answer can only be read once the handler has returned.
    var conn: RpcConnection
    {.cast(gcsafe).}:
      conn = childServer.connection
    asyncSpawn askClientAsync(conn, question)
    %true

  srv.rpc("notifyClient") do():
    var srv: RpcStdioServer
    {.cast(gcsafe).}:
      srv = childServer
    await srv.notify("client/event", default(RequestParamsTx))
    %true

  try:
    waitFor srv.serve()
  except CatchableError:
    discard
  quit(0)

# The suites below run at module scope, so the child has to branch off before
# reaching them - otherwise every spawned server would run the tests too, each
# spawning more servers.
if paramCount() >= 1 and paramStr(1) == ServerArg:
  runChildServer(if paramCount() >= 2: paramStr(2) else: "http")

# ---------------------------------------------------------------------------
# The parent: the tests
# ---------------------------------------------------------------------------

template stdioTests(framingName: static string) =
  suite "JSON-RPC over stdio (" & framingName & " framing)":
    setup:
      var
        router = new RpcRouter
        answered = newAsyncEvent()
        client = newRpcStdioClient(
          router = router, framing = framingByName(framingName)
        )

      router[].rpc("client/answer") do(question: string):
        answered.fire()
        %("re: " & question)

      var notified = newAsyncEvent()
      router[].rpc("client/event") do() -> void:
        notified.fire()

      waitFor client.connect(getAppFilename(), @[ServerArg, framingName])

    teardown:
      waitFor client.close()

    asyncTest "call and response":
      let r = await client.call("hello", %[%"stdio"])
      check r.string == "\"Hello stdio\""
      check client.pendingRequests.len == 0

    asyncTest "message larger than the pipe buffer":
      # 1 MB in one message: the framing has to reassemble it from many reads,
      # and the write has to survive a full pipe.
      let r = await client.call("bigPayload", %[%(1024 * 1024)])
      check r.string.len == 1024 * 1024 + 2 # quotes

    asyncTest "pipelined requests are answered concurrently and correlated":
      var futs: seq[Future[JsonString]]
      for i in 0 ..< 200:
        futs.add client.call("hello", %[%($i)])
      for i in 0 ..< 200:
        check (await futs[i]).string == "\"Hello " & $i & "\""

    asyncTest "requests are answered in order":
      # json_rpc's read loop processes one message at a time - the socket
      # transport included - so a slow request delays the ones queued behind
      # it, and every answer still arrives, correctly correlated.
      let slow = client.call("slow", %[%200, %"slow"])
      let fast = client.call("hello", %[%"fast"])
      check (await slow).string == "\"slow\""
      check (await fast).string == "\"Hello fast\""

    asyncTest "server error is reported to the caller":
      expect(JsonRpcError):
        discard await client.call("boom", %[])
      # the connection survives it
      check (await client.call("hello", %[%"again"])).string == "\"Hello again\""

    asyncTest "server calls back into the client":
      var roundTripped = newAsyncEvent()
      router[].rpc("client/answered") do() -> void:
        roundTripped.fire()

      check (await client.call("askClient", %[%"are you there?"])).string == "true"
      # the client's handler ran ...
      check await answered.wait().withTimeout(2.seconds)
      # ... and its response made it back to the server
      check await roundTripped.wait().withTimeout(2.seconds)

    asyncTest "server notifies the client":
      discard await client.call("notifyClient", %[])
      check await notified.wait().withTimeout(2.seconds)

stdioTests("http")
stdioTests("be32")

suite "stdio transport errors":
  test "connecting to a command that does not exist":
    var client = newRpcStdioClient()
    expect(JsonRpcError):
      waitFor client.connect("no-such-binary-here", @[])

  test "the peer exits when the client closes":
    var client = newRpcStdioClient()
    waitFor client.connect(getAppFilename(), @[ServerArg, "http"])
    check (waitFor client.call("hello", %[%"bye"])).string == "\"Hello bye\""
    waitFor client.close()
    check client.exitCode() == Opt.some(0)
