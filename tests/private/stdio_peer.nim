# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## The peer process for `test_stdio_transport`: a JSON-RPC program whose
## transport is its own standard input/output, which is the way an LSP or MCP
## server is launched. The test spawns it and drives it with an
## `RpcStdioClient`.
##
##   stdio_peer server <framing>   the peer is an RpcStdioServer
##   stdio_peer client <framing>   the peer is an RpcStdioClient with a router
##
## Its standard output carries the protocol, so it must be built with
##   -d:"chronicles_sinks=textlines[stderr]"
##
## The module is also imported by the test itself, for `framingByName`; only
## the `isMainModule` part below runs the peer.

import
  std/[os],
  stew/byteutils,
  ../../json_rpc/[rpcclient, rpcserver],
  ../../json_rpc/clients/stdioclient,
  ../../json_rpc/servers/stdioserver,
  ./helpers

export stdioclient, stdioserver

const PeerExeName* = "stdio_peer"

proc recvMsgJsonLines(
    input: StreamTransport, maxMessageSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, TransportError]).} =
  toBytes(await input.readLine(maxMessageSize, sep = "\n"))

proc sendMsgJsonLines(
    output: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  discard await output.write(msg & toBytes("\n"))

proc framingByName*(name: string): StdioFraming =
  case name
  of "be32": StdioFraming.lengthHeaderBE32()
  of "lines": StdioFraming.init(recvMsgJsonLines, sendMsgJsonLines)
  else: StdioFraming.httpHeader()

proc peerExe*(): string =
  ## The fixture binary, built next to this source by the `test` task.
  currentSourcePath().parentDir() / PeerExeName.addFileExt(ExeExt)

when isMainModule:
  proc logsToStderr(): bool =
    const chronicles_sinks {.strdefine.} = ""
    chronicles_sinks == "textlines[stderr]"

  when not logsToStderr():
    {.error: "the peer needs -d:\"chronicles_sinks=textlines[stderr]\": its stdout carries the protocol".}

  var
    peerServer: RpcStdioServer
    peerClient: RpcStdioClient

  proc askClientAsync(conn: RpcConnection, question: string) {.async: (raises: []).} =
    ## Ask the peer something, then tell it what came back.
    try:
      let answer = await conn.call("client/answer", %[%question])
      await conn.notify("client/answered", default(RequestParamsTx))
      doAssert answer.string == "\"re: " & question & "\"", answer.string
    except CatchableError:
      discard

  proc runServer(framingName: string) {.raises: [CatchableError].} =
    let srv = newRpcStdioServer(framing = framingByName(framingName))
    peerServer = srv

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
      # Server -> client request over the same connection: this is what makes
      # the transport bidirectional rather than a request/response pipe.
      #
      # It is dispatched rather than awaited here because json_rpc's read loop
      # handles one message at a time (the socket transport behaves the same
      # way): awaiting the peer's answer inside a handler would deadlock, since
      # that answer can only be read once the handler has returned.
      var conn: RpcConnection
      {.cast(gcsafe).}:
        conn = peerServer.connection
      asyncSpawn askClientAsync(conn, question)
      %true

    srv.rpc("echoBytes") do(payload: string):
      # Echo the payload back, so a burst of these puts the same volume in
      # flight in both directions at once.
      %payload

    srv.rpc("flood") do(count: int, size: int):
      # Push `count` unsolicited notifications at the peer without waiting for
      # it to read any of them: the server's writes have to survive a stdout
      # pipe that the client is not draining yet.
      var srv: RpcStdioServer
      {.cast(gcsafe).}:
        srv = peerServer
      let chunk = repeat('x', size)
      for i in 0 ..< count:
        await srv.notify(
          "client/flood", paramsTx(%*{"i": i, "payload": chunk}, JrpcConv)
        )
      %count

    srv.rpc("notifyClient") do():
      var srv: RpcStdioServer
      {.cast(gcsafe).}:
        srv = peerServer
      await srv.notify("client/event", default(RequestParamsTx))
      %true

    # Not caught: a broken stream has to reach the exit code, otherwise a
    # failure is indistinguishable from a peer that was closed cleanly.
    waitFor srv.serve()

  proc runClient(framingName: string) {.raises: [CatchableError].} =
    ## The same connection type the test uses, but attached to this process'
    ## own descriptors instead of a spawned peer's.
    var router = new RpcRouter

    router[].rpc("hello") do(name: string):
      %("Hello " & name)

    router[].rpc("bigPayload") do(size: int):
      %repeat('x', size)

    router[].rpc("askClient") do(question: string):
      var conn: RpcConnection
      {.cast(gcsafe).}:
        conn = peerClient
      asyncSpawn askClientAsync(conn, question)
      %true

    let c = newRpcStdioClient(router = router, framing = framingByName(framingName))
    peerClient = c

    c.connect()
    waitFor c.loop

    # `loop` never fails, it records why it stopped - surface that the way
    # `serve` does.
    let failure = c.failure
    if failure != nil:
      raise failure

  let
    mode = if paramCount() >= 1: paramStr(1) else: "server"
    framing = if paramCount() >= 2: paramStr(2) else: "http"

  case mode
  of "client": runClient(framing)
  else: runServer(framing)
  quit(0)
