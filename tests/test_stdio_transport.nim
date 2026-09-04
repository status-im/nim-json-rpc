# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## End-to-end test of the stdio transport, using two processes: the peer
## is `private/stdio_peer`, a program that serves JSON-RPC over its own
## standard input/output, and the test drives it with an `RpcStdioClient`.

import
  std/[json, os, osproc],
  stew/byteutils,
  chronos/asyncproc,
  chronos/unittest2/asynctests,
  ../json_rpc/[rpcclient, rpcserver],
  ../json_rpc/clients/stdioclient,
  ./private/[helpers, stdio_peer]

suite "stdio transport fixture":
  # Required for the rest of tests
  test "the peer program has been built":
    const mode =
      when defined(release):
        "-d:release"
      elif defined(danger):
        "-d:danger"
      else:
        ""
    const flags = "--threads:on -d:chronicles_log_level=ERROR -d:\"chronicles_sinks=textlines[stderr]\""
    const path = "tests" / "private" / "stdio_peer.nim"
    let res = execCmdEx("nim c -f " & mode & " " & flags & " " & path)
    if res.exitCode != 0:
      checkpoint "stdio_peer build output: " & res.output
      fail()

template stdioTests(framingName: string): untyped =
  setup:
    var
      router = new RpcRouter
      answered = newAsyncEvent()
      notified = newAsyncEvent()
      client = newRpcStdioClient(
        router = router, framing = framingByName(framingName)
      )

    router[].rpc("client/answer") do(question: string):
      answered.fire()
      %("re: " & question)

    router[].rpc("client/event") do() -> void:
      notified.fire()

    waitFor client.connect(peerExe(), @["server", framingName])

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

  asyncTest "a burst far larger than the pipe buffer, unread until the end":
    const
      Count = 2048
      Size = 4096
    let payload = repeat('x', Size)
    var futs: seq[Future[JsonString]]
    for i in 0 ..< Count:
      futs.add client.call("echoBytes", %[%payload])

    var got = 0
    for i in 0 ..< Count:
      let resp = await futs[i].withTimeout(30.seconds)
      check resp
      if not resp:
        break
      check futs[i].read().string.len == Size + 2 # quotes
      inc got
    check got == Count

  asyncTest "the peer floods us with notifications while we keep requesting":
    const
      Count = 512
      Size = 2048
    var
      seen = 0
      allSeen = newAsyncEvent()
    router[].rpc("client/flood") do(i: int, payload: string) -> void:
      inc seen
      if seen == Count:
        allSeen.fire()

    let flooding = client.call("flood", %[%Count, %Size])
    # Keep our own requests going while the flood is in flight.
    for i in 0 ..< 64:
      check (await client.call("hello", %[%($i)])).string == "\"Hello " & $i & "\""

    check await flooding.withTimeout(30.seconds)
    check await allSeen.wait().withTimeout(30.seconds)
    check seen == Count

suite "stdio http framing":
  stdioTests("http")

suite "stdio be32 framing":
  stdioTests("be32")

suite "stdio lines framing":
  stdioTests("lines")

suite "stdio bidirectional":
  setup:
    var
      router = new RpcRouter
      answered = newAsyncEvent()
      roundTripped = newAsyncEvent()
      client = newRpcStdioClient(router = router, framing = framingByName("http"))

    router[].rpc("client/answer") do(question: string):
      answered.fire()
      %("re: " & question)

    router[].rpc("client/answered") do() -> void:
      roundTripped.fire()

    waitFor client.connect(peerExe(), @["client", "http"])

  teardown:
    waitFor client.close()

  asyncTest "call and response":
    check (await client.call("hello", %[%"stdio"])).string == "\"Hello stdio\""

  asyncTest "message larger than the pipe buffer":
    check (await client.call("bigPayload", %[%(1024 * 1024)])).string.len ==
      1024 * 1024 + 2

  asyncTest "the peer calls back into us":
    check (await client.call("askClient", %[%"are you there?"])).string == "true"
    check await answered.wait().withTimeout(2.seconds)
    check await roundTripped.wait().withTimeout(2.seconds)

suite "malformed framing":
  proc runPeer(input: string): int =
    proc run(): Future[int] {.async.} =
      let p = await startProcess(
        peerExe(),
        arguments = @["server", "http"],
        stdinHandle = AsyncProcess.Pipe,
        stdoutHandle = AsyncProcess.Pipe,
      )
      try:
        if input.len > 0:
          await p.stdinStream.write(input)
        await p.stdinStream.tsource.closeWait()
        # Drain stdout so the peer never blocks writing to a full pipe.
        let
          outFut = p.stdoutStream.read()
          code = await p.waitForExit(5.seconds)
        await allFutures(outFut)
        code
      finally:
        await p.closeWait()

    waitFor run()

  const
    jsonRequest =
      """{"jsonrpc":"2.0","id":1,"method":"hello","params":{"input":"world"}}"""
    jsonFrame = "Content-Length: " & $jsonRequest.len & "\r\n\r\n" & jsonRequest

  test "a well framed request is served, then the peer exits cleanly":
    check runPeer(jsonFrame) == 0

  test "a peer that is closed without being spoken to exits cleanly":
    check runPeer("") == 0

  test "a negative content length fails":
    check runPeer("Content-Length: -5\r\n\r\nxxxxx") != 0

  test "a content length that is not a number fails":
    check runPeer("Content-Length: abc\r\n\r\nxxxxx") != 0

  test "a content length beyond the maximum message size fails":
    check runPeer("Content-Length: 999999999\r\n\r\nshort") != 0

  test "a header that cannot be parsed fails":
    check runPeer("total nonsense here\r\n\r\n") != 0

  test "an unframed message ends the session":
    check runPeer(jsonRequest) == 0

  test "a header that is never terminated ends the session":
    check runPeer("Content-Length: 47") == 0

  test "a body shorter than the declared length ends the session":
    check runPeer("Content-Length: 500\r\n\r\n" & jsonRequest) == 0

  test "a header longer than the limit fails":
    check runPeer(repeat('A', 5000)) != 0

  test "a valid request after a broken frame is not served":
    check runPeer("Content-Length: -5\r\n\r\n" & jsonFrame) != 0

suite "stdio transport errors":
  test "connecting to a command that does not exist":
    var client = newRpcStdioClient()
    expect(JsonRpcError):
      waitFor client.connect("no-such-binary-here", @[])

  test "the peer exits when the client closes":
    var client = newRpcStdioClient()
    waitFor client.connect(peerExe(), @["server", "http"])
    check (waitFor client.call("hello", %[%"bye"])).string == "\"Hello bye\""
    waitFor client.close()
    check client.exitCode() == Opt.some(0)
