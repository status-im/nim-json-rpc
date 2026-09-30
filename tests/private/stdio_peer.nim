# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Usage:
##
##   stdio_peer <framing>        the peer is an RpcStdioServer
##   stdio_peer <framing> hook   same, created with a processClientHook

{.push gcsafe, raises: [].}

import
  std/[os],
  chronicles,
  ../../json_rpc/[rpcclient, rpcserver],
  ../../json_rpc/servers/stdioserver,
  ../../json_rpc/private/shared_wrapper,
  ./[helpers, stdio_framing]

when isMainModule:
  proc askClientAsync(conn: RpcConnection, question: string) {.async: (raises: []).} =
    ## Ask the peer something, then tell it what came back.
    try:
      let answer = await conn.call("client/answer", %[%question])
      await conn.notify("client/answered", default(RequestParamsTx))
      doAssert answer.string == "\"re: " & question & "\"", answer.string
    except CatchableError:
      discard

  proc runServer(framingName: string, hook: bool) {.raises: [CatchableError].} =
    var hookedServer: RpcStdioServer
    let srv =
      if hook:
        newRpcStdioServer(
          proc(
              server: RpcStdioServer, input, output: StreamTransport
          ): Future[void] {.async: (raises: [], raw: true).} =
            hookedServer = server
            processClient(server, input, output),
          framing = framingByName(framingName),
        )
      else:
        newRpcStdioServer(framing = framingByName(framingName))

    srv.rpc(JrpcConv):
      proc hello(name: string): string =
        "Hello " & name

      proc bigPayload(size: int): string =
        repeat('x', size)

      proc slow(ms: int, tag: string): string {.async: (raises: [CancelledError]).} =
        await sleepAsync(ms.milliseconds)
        tag

      proc boom(): void {.raises: [ValueError].} =
        raise (ref ValueError)(msg: "boom")

      proc askClient(question: string): bool =
        # Server -> client request over the same connection: this is what makes
        # the transport bidirectional rather than a request/response pipe.
        #
        # It is dispatched rather than awaited here because json_rpc's read loop
        # handles one message at a time (the socket transport behaves the same
        # way): awaiting the peer's answer inside a handler would deadlock, since
        # that answer can only be read once the handler has returned.
        asyncSpawn askClientAsync(srv.connection, question)
        true

      proc echoBytes(payload: string): string =
        # Echo the payload back, so a burst of these puts the same volume in
        # flight in both directions at once.
        payload

      proc flood(count: int, size: int): int {.async: (raises: [CancelledError]).} =
        # Push `count` unsolicited notifications at the peer without waiting for
        # it to read any of them: the server's writes have to survive a stdout
        # pipe that the client is not draining yet.
        let chunk = repeat('x', size)
        for i in 0 ..< count:
          await srv.notify(
            "client/flood", paramsTx(%*{"i": i, "payload": chunk}, JrpcConv)
          )
        count

      proc notifyClient(): bool {.async: (raises: [CancelledError]).} =
        await srv.notify("client/event", default(RequestParamsTx))
        true

      proc hooked(): bool =
        # Whether the hook was given this server
        hookedServer != nil and hookedServer == srv

      proc stopServer(): void =
        # `stop` waits for the read loop, which waits for this handler
        asyncSpawn srv.stop()

    waitFor srv.serve()

  let
    framing = if paramCount() >= 1: paramStr(1) else: "http"
    hook = paramCount() >= 2 and paramStr(2) == "hook"

  try:
    runServer(framing, hook)
  except JsonRpcError as exc:
    error "stdio_peer error", err = exc.msg
    quit(1)
  quit(0)
