# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Framings and the location of the `stdio_peer` fixture, shared by the peer
## and the tests.

{.push gcsafe, raises: [].}

import
  std/os,
  stew/byteutils,
  chronos,
  ../../json_rpc/clients/shared/framing

export framing

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
