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
##   stdio_peer <framing>   the peer is an RpcStdioServer

{.push gcsafe, raises: [].}

import
  std/[os],
  stew/byteutils,
  ../../json_rpc/[rpcclient, rpcserver],
  ../../json_rpc/clients/stdioclient,
  ../../json_rpc/servers/stdioserver,
  ../../json_rpc/private/shared_wrapper,
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

proc framingByName*(name: string): Framing =
  case name
  of "be32":
    Framing.lengthHeaderBE32()
  of "lines":
    Framing.init(recvMsgJsonLines, sendMsgJsonLines)
  of "http":
    Framing.httpHeader()
  else:
    raiseAssert "framing not found: " & name

proc peerExe*(): string =
  ## The fixture binary, built next to this source by the `test` task.
  currentSourcePath().parentDir() / PeerExeName.addFileExt(ExeExt)

when isMainModule:
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

    waitFor srv.serve()

  let framing = if paramCount() >= 1: paramStr(1) else: "http"

  try:
    runServer(framing)
  except JsonRpcError as exc:
    echo "stdio_peer error: " & exc.msg
    quit(1)
  quit(0)
