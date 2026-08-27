# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## JSON-RPC over standard input/output.
##
## This is the transport language servers (LSP) and MCP servers speak: the peer
## is reached through a pair of pipes rather than a socket, so the two halves of
## the connection are two distinct descriptors - an input transport that is only
## read and an output transport that is only written. Apart from that, it is the
## same bidirectional connection as the socket client: messages are delimited by
## a pluggable framing, responses are correlated with pending requests, and
## incoming requests are dispatched through the connection's router.
##
## Two ways to connect:
##
## * `connect(client)` speaks JSON-RPC over *this* process' own stdin/stdout,
##   which is what an LSP/MCP server does.
## * `connect(client, command, arguments)` spawns a child process and speaks
##   JSON-RPC over its stdin/stdout, which is what an editor does when it
##   launches a language server.
##
## Standard output carries the protocol, so nothing else may write to it - and
## chronicles, which json-rpc itself logs through, writes there unless told
## otherwise. Build programs using their own stdio with the log sinks pointed at
## standard error:
##
##   -d:"chronicles_sinks=textlines[stderr]"
##
## and keep `echo` out of them.

{.push raises: [], gcsafe.}

import
  std/strtabs,
  stew/[arrayops, byteutils, endians2],
  chronicles,
  chronos/asyncproc,
  chronos/osutils,
  httputils,
  ../[client, errors, router],
  ../private/jrpc_sys

when defined(windows):
  import chronos/osdefs

export client, errors, asyncproc

when not declared(newSeqUninit): # nim 2.2+
  template newSeqUninit[T: byte](len: int): seq[byte] =
    newSeqUninitialized[byte](len)

logScope:
  topics = "jsonrpc client stdio"

type
  RpcStdioClient* = ref object of RpcConnection
    ## Bidirectional connection over a pair of pipes, with pluggable framing
    ## options for delineating messages.
    input*: StreamTransport
      ## The half messages are read from - the peer's standard output.
    output*: StreamTransport
      ## The half messages are written to - the peer's standard input.
    loop*: Future[void]
    framing*: StdioFraming
    process*: AsyncProcessRef
      ## The peer process, when this client spawned one; `nil` when the client
      ## is attached to this process' own standard input/output.
    peerExitCode: Opt[int]
      ## Exit status of the peer process, once it has been waited for.

  StdioFraming* = object
    ## Message delimiting. Unlike a socket, the two halves of the connection
    ## are separate descriptors, so receiving and sending take one each.
    recvMsg: proc(input: StreamTransport, limit: int): Future[seq[byte]] {.
      async: (raises: [CancelledError, TransportError]), nimcall
    .}
    sendMsg: proc(output: StreamTransport, msg: seq[byte]) {.
      async: (raises: [CancelledError, TransportError]), nimcall
    .}

# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------

proc recvMsgNewLine(
    input: StreamTransport, maxMessageSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, TransportError]).} =
  let data = await input.readLine(maxMessageSize, sep = "\r\n")
  toBytes(data)

proc sendMsgNewLine(
    output: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  discard await output.write(msg & toBytes("\r\n"))

proc newLine*(
    T: type StdioFraming
): T {.deprecated: "Prefer lengthHeaderBE32 or httpHeader in in new applications".} =
  ## A framing that suffixes messages with "\r\n", for peers that speak
  ## newline-delimited JSON.
  ##
  ## The framing can only be used with payloads that do not contain newlines and
  ## message length is checked only after that many bytes have been transmitted.
  T(recvMsg: recvMsgNewLine, sendMsg: sendMsgNewLine)

proc recvMsgHttpHeader(
    input: StreamTransport, maxMessageSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, TransportError]).} =
  var buf {.noinit.}: array[1024, byte]
  let
    bytes = await input.readUntil(addr buf[0], buf.len, toBytes("\r\n\r\n"))
    headers = parseHeaders(buf.toOpenArray(0, bytes - 1), true)

  let len = headers.contentLength()
  if len <= 0 or len > maxMessageSize:
    return

  result = newSeqUninit[byte](len)
  await input.readExactly(addr result[0], result.len)

proc sendMsgHttpHeader(
    output: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  const field = toBytes("Content-Length: ")
  const separator = toBytes("\r\n\r\n")
  discard await output.write(field & toBytes($msg.len) & separator & msg)

proc httpHeader*(T: type StdioFraming): T =
  ## Framing using a HTTP-like `Content-Length: <length>\r\n` header followed by
  ## an empty line ("\r\n") followed by the message itself.
  ##
  ## This is the encoding LSP and MCP peers speak over stdio, and the default
  ## for this transport. It is compatible with the default encoding used by
  ## StreamJsonRPC and https://www.npmjs.com/package/vscode-jsonrpc.
  T(recvMsg: recvMsgHttpHeader, sendMsg: sendMsgHttpHeader)

proc recvMsgLengthHeaderBE32(
    input: StreamTransport, maxMessageSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, TransportError]).} =
  var
    pos: int
    lenBE32: array[4, byte]
    payload: seq[byte]
    error: ref TransportError

  proc predicate(data: openArray[byte]): tuple[consumed: int, done: bool] =
    if data.len == 0:
      return (0, true)

    var dataPos = 0

    if payload.len == 0:
      let n = lenBE32.toOpenArray(pos, lenBE32.high()).copyFrom(data)
      pos += n
      dataPos += n

      if pos < 4:
        return (dataPos, false)

      let messageSize = uint32.fromBytesBE(lenBE32)
      if uint64(messageSize) > uint64(maxMessageSize):
        error =
          (ref TransportLimitError)(msg: "Maximum length exceeded: " & $messageSize)
        return (dataPos, true)

      if messageSize == 0:
        return (dataPos, true)

      payload = newSeqUninit[byte](int(messageSize))
      pos = 0

    let n = payload.toOpenArray(pos, payload.high()).copyFrom(
        data.toOpenArray(dataPos, data.high())
      )

    pos += n
    dataPos += n

    (dataPos, pos == payload.len())

  await input.readMessage(predicate)

  if error != nil:
    raise error

  payload

proc sendMsgLengthHeaderBE32(
    output: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  var header = msg.len.uint32.toBytesBE()
  discard await output.write(@header & msg)

proc lengthHeaderBE32*(T: type StdioFraming): T =
  ## Framing using a big-endian 32-bit length prefix - the most efficient
  ## option, for peers that are not bound to the LSP/MCP encoding.
  T(recvMsg: recvMsgLengthHeaderBE32, sendMsg: sendMsgLengthHeaderBE32)

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc new*(
    T: type RpcStdioClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(RpcRouterCallback),
    framing = StdioFraming.httpHeader(),
): T =
  T(maxMessageSize: maxMessageSize, router: router, framing: framing)

proc new*(
    T: type RpcStdioClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
    framing = StdioFraming.httpHeader(),
): T =
  let router =
    if router != nil:
      proc(
          request: RequestBatchRx
      ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
        router[].route(request)
    else:
      nil
  T.new(maxMessageSize, router, framing)

proc newRpcStdioClient*(
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
    framing = StdioFraming.httpHeader(),
): RpcStdioClient =
  ## Creates a new client instance.
  RpcStdioClient.new(maxMessageSize, router, framing)

# ---------------------------------------------------------------------------
# Sending
# ---------------------------------------------------------------------------

method send*(
    client: RpcStdioClient, reqData: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if client.output.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )
  try:
    await client.framing.sendMsg(client.output, reqData)
  except TransportError as exc:
    raise (ref RpcPostError)(msg: exc.msg, parent: exc)

method request(
    client: RpcStdioClient, reqData: seq[byte], id: int
): Future[ResponseBatchRx] {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Remotely calls the specified RPC method.
  if client.output.isNil:
    raise newException(
      RpcTransportError, "Transport is not initialised (missing a call to connect?)"
    )

  client.withPendingFut(fut, id):
    try:
      await client.framing.sendMsg(client.output, reqData)
    except TransportError as exc:
      raise (ref RpcPostError)(msg: exc.msg, parent: exc)

    await fut

# ---------------------------------------------------------------------------
# Message loop
# ---------------------------------------------------------------------------

proc processMessages(client: RpcStdioClient) {.async: (raises: []).} =
  let maxMessageSize =
    if client.maxMessageSize == 0: defaultMaxMessageSize else: client.maxMessageSize

  var lastError: ref JsonRpcError
  while not client.input.atEof():
    try:
      let data = await client.framing.recvMsg(client.input, maxMessageSize)
      if data.len == 0:
        break

      let fallback = client.callOnProcessMessage(data).valueOr:
        lastError = (ref RequestDecodeError)(msg: error, payload: data)
        break

      if not fallback:
        continue

      let resp =
        try:
          await client.processMessage(data)
        except InvalidResponse as exc:
          raise exc
        except JsonRpcError as exc:
          try:
            await client.framing.sendMsg(
              client.output, wrapError(router.INVALID_REQUEST, exc.msg)
            )
          except TransportError:
            discard
          raise exc

      if resp.len > 0:
        await client.framing.sendMsg(client.output, resp)
    except CatchableError as exc:
      lastError = (ref RpcTransportError)(msg: exc.msg, parent: exc)
      break

  if lastError == nil:
    lastError = (ref RpcTransportError)(msg: "Connection closed")

  # Prevent new requests
  let
    input = move(client.input)
    output = move(client.output)
  client.clearPending(lastError)

  await input.closeWait()
  await output.closeWait()

  if not client.onDisconnect.isNil:
    client.onDisconnect()

proc attach*(
    client: RpcStdioClient,
    input, output: StreamTransport,
    remote: string,
) {.async: (raises: [], raw: true).} =
  client.input = input
  client.output = output
  client.remote = remote

  processMessages(client)

# ---------------------------------------------------------------------------
# Connecting
# ---------------------------------------------------------------------------

proc stdioTransports*(): tuple[input, output: StreamTransport] {.raises: [JsonRpcError]} =
  ## Wrap this process standard input and standard output in chronos transports.
  when defined(windows):
    let
      inHandle = getStdHandle(STD_INPUT_HANDLE)
      outHandle = getStdHandle(STD_OUTPUT_HANDLE)
    if inHandle == INVALID_HANDLE_VALUE or outHandle == INVALID_HANDLE_VALUE:
      raise (ref RpcTransportError)(msg: "Unable to obtain the standard handles")
    let
      inFd = AsyncFD(inHandle)
      outFd = AsyncFD(outHandle)
  else:
    let
      inFd = AsyncFD(0)
      outFd = AsyncFD(1)
    for fd in [cint(0), cint(1)]:
      setDescriptorBlocking(fd, false).isOkOr:
        raise (ref RpcTransportError)(
          msg: "Unable to switch standard descriptor " & $fd &
            " to non-blocking mode: " & osErrorMsg(error)
        )

  try:
    (fromPipe(inFd), fromPipe(outFd))
  except TransportOsError as exc:
    raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

proc connect*(client: RpcStdioClient) {.raises: [JsonRpcError].} =
  ## Speak JSON-RPC over this process' own standard input and output. The
  ## message loop runs until standard input reaches end of file; await
  ## `client.loop` to wait for that.
  ##
  ## Nothing else may write to standard output - see the module documentation.
  let (input, output) = stdioTransports()
  client.loop = client.attach(input, output, "stdio")

proc connect*(
    client: RpcStdioClient,
    command: string,
    arguments: seq[string] = @[],
    workingDir = "",
    environment: StringTableRef = nil,
    options: set[AsyncProcessOption] = {},
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  ## Spawn `command` and speak JSON-RPC over its standard input and output.
  ##
  ## The child's stderr is inherited, so its diagnostics reach the terminal
  ## without disturbing the protocol.
  let process =
    try:
      await startProcess(
        command,
        workingDir = workingDir,
        arguments = arguments,
        environment = environment,
        options = options,
        stdinHandle = AsyncProcess.Pipe,
        stdoutHandle = AsyncProcess.Pipe,
      )
    except AsyncProcessError as exc:
      raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

  client.process = process
  # The pipes chronos created for the child are wrapped in async streams; the
  # transports underneath them are what the framing works with.
  client.loop =
    client.attach(process.stdoutStream.tsource, process.stdinStream.tsource, command)

method close*(client: RpcStdioClient) {.async: (raises: []).} =
  ## Close the connection and, if this client spawned the peer, wait for it to
  ## exit. The child sees end of file on its standard input, which is how a
  ## well behaved server is asked to shut down.
  if client.loop != nil:
    let loop = move(client.loop)
    await loop.cancelAndWait()

  if client.process != nil:
    let process = move(client.process)
    try:
      client.peerExitCode = Opt.some(await process.waitForExit(InfiniteDuration))
    except AsyncProcessError, CancelledError:
      discard
    await process.closeWait()

proc exitCode*(client: RpcStdioClient): Opt[int] =
  ## Exit status of the spawned peer, once it has one - after `close`, or once
  ## a peer that exited on its own has been reaped.
  if client.peerExitCode.isSome():
    client.peerExitCode
  elif client.process == nil:
    Opt.none(int)
  else:
    let res = client.process.peekExitCode()
    if res.isOk() and res.get() >= 0: Opt.some(res.get()) else: Opt.none(int)

{.pop.}
