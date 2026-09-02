# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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

  when not compileOption("threads"):
    {.error: "the stdio transport needs --threads:on on Windows".}

export client, errors, asyncproc

when not declared(newSeqUninit): # nim 2.2+
  template newSeqUninit[T: byte](len: int): seq[byte] =
    newSeqUninitialized[byte](len)

logScope:
  topics = "jsonrpc client stdio"

type
  RpcStdioClient* = ref object of RpcConnection
    ## Bidirectional connection over a pair of pipes
    input*: StreamTransport
    output*: StreamTransport
    loop*: Future[void]
    framing*: StdioFraming
    process*: AsyncProcessRef
    peerExitCode: Opt[int]

  StdioRecvMsg* = proc(input: StreamTransport, limit: int): Future[seq[byte]] {.
    async: (raises: [CancelledError, TransportError]), nimcall
  .}

  StdioSendMsg* = proc(output: StreamTransport, msg: seq[byte]) {.
    async: (raises: [CancelledError, TransportError]), nimcall
  .}

  StdioFraming* = object
    recvMsg: StdioRecvMsg
    sendMsg: StdioSendMsg

# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------

proc init*(T: type StdioFraming, recvMsg: StdioRecvMsg, sendMsg: StdioSendMsg): T =
  T(recvMsg: recvMsg, sendMsg: sendMsg)

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

when defined(windows):
  const BridgeBufSize = 8192

  type PumpCtx = object
    src, dst: HANDLE

  var
    stdinPump: Thread[PumpCtx]
    stdoutPump: Thread[PumpCtx]

  proc pump(ctx: PumpCtx) {.thread.} =
    var buf {.noinit.}: array[BridgeBufSize, byte]
    block copy:
      while true:
        var count = DWORD(0)
        if readFile(ctx.src, addr buf[0], DWORD(len(buf)), addr count, nil) == FALSE:
          break copy
        if count == 0:
          break copy
        var sent = 0
        while sent < int(count):
          var written = DWORD(0)
          let ok = writeFile(
            ctx.dst, addr buf[sent], DWORD(int(count) - sent), addr written, nil
          )
          if ok == FALSE or written == 0:
            break copy
          sent += int(written)
    discard closeHandle(ctx.dst)

  proc bridgeStdio(): tuple[input, output: StreamTransport] {.raises: [JsonRpcError].} =
    let
      inHandle = getStdHandle(STD_INPUT_HANDLE)
      outHandle = getStdHandle(STD_OUTPUT_HANDLE)
    if inHandle == INVALID_HANDLE_VALUE or outHandle == INVALID_HANDLE_VALUE:
      raise (ref RpcTransportError)(msg: "Unable to obtain the standard handles")

    const
      loopEnd = {DescriptorFlag.CloseOnExec, DescriptorFlag.NonBlock}
      threadEnd = {DescriptorFlag.CloseOnExec}
    let
      inPipe = createOsPipe(loopEnd, threadEnd).valueOr:
        raise (ref RpcTransportError)(
          msg: "Unable to create the standard input bridge: " & osErrorMsg(error)
        )
      outPipe = createOsPipe(threadEnd, loopEnd).valueOr:
        raise (ref RpcTransportError)(
          msg: "Unable to create the standard output bridge: " & osErrorMsg(error)
        )

    try:
      createThread(stdinPump, pump, PumpCtx(src: inHandle, dst: inPipe.write))
      createThread(stdoutPump, pump, PumpCtx(src: outPipe.read, dst: outHandle))
    except ResourceExhaustedError as exc:
      raise (ref RpcTransportError)(
        msg: "Unable to start the standard input/output bridge: " & exc.msg,
        parent: exc,
      )

    try:
      (fromPipe(AsyncFD(inPipe.read)), fromPipe(AsyncFD(outPipe.write)))
    except TransportOsError as exc:
      raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

proc stdioTransports*(): tuple[input, output: StreamTransport] {.raises: [JsonRpcError]} =
  when defined(windows):
    bridgeStdio()
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
  client.loop = client.attach(process.stdoutStream.tsource, process.stdinStream.tsource, command)

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
