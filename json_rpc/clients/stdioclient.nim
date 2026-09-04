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

const stdioBridge* = defined(windows) or defined(jsonRpcStdioBridge)
  ## Whether the standard descriptors reach the event loop through a pipe pair
  ## fed by a pair of blocking pump threads, instead of being handed to it
  ## directly. Always so on Windows, whose standard handles cannot be used for
  ## overlapped IO; `-d:jsonRpcStdioBridge` turns the same machinery on for
  ## POSIX, so that the Windows code path can be run and debugged on a POSIX
  ## host.

when defined(windows):
  import chronos/osdefs
else:
  from std/posix import nil

when stdioBridge:
  when not compileOption("threads"):
    {.error: "the stdio transport bridge needs --threads:on".}

export client, errors, asyncproc

when not declared(newSeqUninit): # nim 2.2+
  template newSeqUninit[T: byte](len: int): seq[byte] =
    newSeqUninitialized[byte](len)

logScope:
  topics = "jsonrpc client stdio"

const DefaultPeerExitTimeout* = 30.seconds
  ## How long `close` gives a spawned peer to exit after its standard input has
  ## been closed, before killing it.

const PeerExitPollInterval = 25.milliseconds
  ## How often `close` asks the operating system directly whether the peer has
  ## exited, alongside waiting to be told.

const PeerExitNotifyGrace = 1.seconds
  ## How far the event loop's notification may lag the operating system before
  ## the lag is itself the bug worth reporting. Normal latency is microseconds.

const stdioTraceEnabled* = defined(jsonRpcStdioTrace)
  ## Trace the lifecycle of the stdio transport on stderr, for diagnosing a
  ## connection that stops making progress. Built with `-d:jsonRpcStdioTrace`.
  ##
  ## This deliberately bypasses chronicles: the pump threads run outside the
  ## event loop, and a hang leaves anything buffered unwritten - which is
  ## exactly the output that would have said where it hung. Each line is a
  ## single unbuffered write to the standard error descriptor instead, so lines
  ## survive a hang and cannot interleave with each other.

when stdioTraceEnabled:
  let stdioTraceStart = Moment.now()

  proc stdioProcessId(): int =
    when defined(windows):
      int(getCurrentProcessId())
    else:
      int(posix.getpid())

  proc stdioTraceWrite*(msg: string) {.gcsafe, raises: [].} =
    let line =
      "[stdio pid=" & $stdioProcessId() & " +" &
      $(Moment.now() - stdioTraceStart).milliseconds & "ms] " & msg & "\n"
    when defined(windows):
      var written = DWORD(0)
      discard writeFile(
        getStdHandle(STD_ERROR_HANDLE), unsafeAddr line[0], DWORD(len(line)),
        addr written, nil,
      )
    else:
      discard posix.write(cint(2), unsafeAddr line[0], len(line))

template stdioTrace*(msg: untyped) =
  ## No-op, argument included, unless `-d:jsonRpcStdioTrace` is set.
  when stdioTraceEnabled:
    stdioTraceWrite(msg)

type
  RpcStdioClient* = ref object of RpcConnection
    ## Bidirectional connection over a pair of pipes
    input*: StreamTransport
    output*: StreamTransport
    loop*: Future[void]
    framing*: StdioFraming
    process*: AsyncProcessRef
    peerExitTimeout*: Duration
      ## How long `close` waits for a spawned peer to exit on its own before
      ## killing it. `DefaultPeerExitTimeout` when left at zero.
    peerExitCode: Opt[int]
    lastFailure: ref JsonRpcError

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
  let bytes = await input.readUntil(addr buf[0], buf.len, toBytes("\r\n\r\n"))

  let headers = parseHeaders(buf.toOpenArray(0, bytes - 1), true)
  if headers.failed():
    raise (ref TransportError)(msg: "Malformed message header")

  let len = headers.contentLength()
  if len < 0:
    raise (ref TransportError)(msg: "Malformed content length")
  if len > maxMessageSize:
    raise (ref TransportLimitError)(msg: "Maximum length exceeded: " & $len)
  if len == 0:
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
  T(
    maxMessageSize: maxMessageSize,
    router: router,
    framing: framing,
    peerExitTimeout: DefaultPeerExitTimeout,
  )

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

  stdioTrace("loop: started for " & client.remote)
  var lastError: ref JsonRpcError
  while not client.input.atEof():
    try:
      let data = await client.framing.recvMsg(client.input, maxMessageSize)
      stdioTrace("loop: received " & $data.len & " bytes")
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
        stdioTrace("loop: sending " & $resp.len & " bytes")
        await client.framing.sendMsg(client.output, resp)
        stdioTrace("loop: sent " & $resp.len & " bytes")
    except TransportIncompleteError as exc:
      debug "Stdio connection ended", err = exc.msg, remote = client.remote
      break
    except CatchableError as exc:
      lastError = (ref RpcTransportError)(msg: exc.msg, parent: exc)
      break

  if lastError == nil:
    lastError = (ref RpcTransportError)(msg: "Connection closed")
  else:
    error "Stdio connection failed", err = lastError.msg, remote = client.remote
    client.lastFailure = lastError

  # Prevent new requests
  let
    input = move(client.input)
    output = move(client.output)
  client.clearPending(lastError)

  stdioTrace("loop: ended (" & lastError.msg & "), closing the transports")
  await input.closeWait()
  await output.closeWait()
  stdioTrace("loop: the transports are closed")

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

when stdioBridge:
  const BridgeBufSize = 8192

  when defined(windows):
    type PumpFd = HANDLE
  else:
    type PumpFd = cint

  type PumpCtx = object
    src, dst: PumpFd
    name: cstring
      ## A literal, not a `string`: this crosses a thread boundary.

  var
    stdinPump: Thread[PumpCtx]
    stdoutPump: Thread[PumpCtx]
    bridgeActive = false

  proc readOnce(fd: PumpFd, data: pointer, size: int): int =
    ## Bytes read; zero at end of stream, negative on error.
    when defined(windows):
      var count = DWORD(0)
      if readFile(fd, data, DWORD(size), addr count, nil) == FALSE:
        -1
      else:
        int(count)
    else:
      handleEintr(posix.read(fd, data, size))

  proc writeOnce(fd: PumpFd, data: pointer, size: int): int =
    ## Bytes written; anything but a positive count means the far end is gone.
    when defined(windows):
      var count = DWORD(0)
      if writeFile(fd, data, DWORD(size), addr count, nil) == FALSE:
        -1
      else:
        int(count)
    else:
      handleEintr(posix.write(fd, data, size))

  proc closePumpFd(fd: PumpFd) =
    when defined(windows):
      discard closeHandle(fd)
    else:
      discard closeFd(fd)

  proc pump(ctx: PumpCtx) {.thread.} =
    ## Copy `src` to `dst` with blocking reads and writes until either end goes
    ## away - what the event loop itself cannot do to a standard descriptor.
    let name = $ctx.name
    stdioTrace("pump " & name & ": started")
    var
      buf {.noinit.}: array[BridgeBufSize, byte]
      total = 0
    block copy:
      while true:
        let count = readOnce(ctx.src, addr buf[0], len(buf))
        if count <= 0:
          stdioTrace(
            "pump " & name & ": read ended, count=" & $count & " err=" &
            $int(osLastError()) & " total=" & $total
          )
          break copy
        var sent = 0
        while sent < count:
          let written = writeOnce(ctx.dst, addr buf[sent], count - sent)
          if written <= 0:
            stdioTrace(
              "pump " & name & ": write ended, written=" & $written & " err=" &
              $int(osLastError()) & " total=" & $total
            )
            break copy
          sent += written
        total += sent
    closePumpFd(ctx.dst)
    stdioTrace("pump " & name & ": closed its output and is exiting, total=" & $total)

  proc stdioFds(): tuple[input, output: PumpFd] {.raises: [JsonRpcError].} =
    when defined(windows):
      let
        inHandle = getStdHandle(STD_INPUT_HANDLE)
        outHandle = getStdHandle(STD_OUTPUT_HANDLE)
      if inHandle == INVALID_HANDLE_VALUE or outHandle == INVALID_HANDLE_VALUE:
        raise (ref RpcTransportError)(msg: "Unable to obtain the standard handles")
      result.input = inHandle
      result.output = outHandle
    else:
      # The pumps read and write these from a thread, so a parent that handed
      # us non-blocking descriptors would leave them spinning on EAGAIN.
      for fd in [cint(0), cint(1)]:
        setDescriptorBlocking(fd, true).isOkOr:
          raise (ref RpcTransportError)(
            msg: "Unable to switch standard descriptor " & $fd &
              " to blocking mode: " & osErrorMsg(error)
          )
      result.input = cint(0)
      result.output = cint(1)

  proc bridgeStdio(): tuple[input, output: StreamTransport] {.raises: [JsonRpcError].} =
    let (inHandle, outHandle) = stdioFds()

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
      createThread(
        stdinPump, pump, PumpCtx(src: inHandle, dst: inPipe.write, name: "stdin")
      )
      createThread(
        stdoutPump, pump, PumpCtx(src: outPipe.read, dst: outHandle, name: "stdout")
      )
      bridgeActive = true
      stdioTrace("bridge: both pumps running")
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
  when stdioBridge:
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

    stdioTrace("transports: using the standard descriptors directly")
    try:
      (fromPipe(inFd), fromPipe(outFd))
    except TransportOsError as exc:
      raise (ref RpcTransportError)(msg: exc.msg, parent: exc)

proc flushStdioBridge*() =
  ## Wait for the outbound pump to finish copying whatever the event loop wrote
  ## into the bridge out to the real standard output, then let it exit.
  ##
  ## Call this after the connection has closed and before `quit`. The pumps are
  ## detached threads, so `quit` would otherwise cut the outbound one off mid
  ## copy and the last message written - typically the reply the peer was asked
  ## for - would never leave the process. A no-op when the transport is not
  ## bridged, and safe to call more than once.
  ##
  ## The pump only ends once the loop's end of the bridge is closed, which is
  ## what tells it there is nothing more to copy; that happens when the
  ## connection's message loop finishes, so this must come after it.
  when stdioBridge:
    if bridgeActive:
      bridgeActive = false
      stdioTrace("bridge: waiting for the outbound pump to drain")
      joinThread(stdoutPump)
      stdioTrace("bridge: the outbound pump has drained")

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

proc peerHasExited(process: AsyncProcessRef): bool =
  ## Ask the operating system directly whether the peer is gone.
  ##
  ## Windows only, and deliberately: there `peekExitCode` is
  ## `GetExitCodeProcess`, a side effect free query. The POSIX one is
  ## `waitpid(WNOHANG)`, which *reaps* the child, and reaping it behind
  ## `waitForExit`'s back can leave that waiting on a notification for a child
  ## that no longer exists.
  when defined(windows):
    let res = process.peekExitCode()
    res.isOk() and res.get() >= 0
  else:
    false

proc awaitPeerExit(
    client: RpcStdioClient, process: AsyncProcessRef, timeout: Duration
) {.async: (raises: []).} =
  ## Wait for a spawned peer to exit.
  ##
  ## `waitForExit` is the event loop's answer and stays the only source of the
  ## exit status. On Windows it is shadowed by a poll that only *observes*,
  ## because the two failures behind a peer that will not go away are
  ## indistinguishable from the outside and want opposite fixes: a peer that is
  ## genuinely still running, and a peer that exited without the loop ever
  ## being told.
  let
    started = Moment.now()
    waiter = process.waitForExit(timeout)
  var exitSeenAt = Opt.none(Moment)

  while not waiter.finished():
    if exitSeenAt.isNone() and peerHasExited(process):
      exitSeenAt = Opt.some(Moment.now())
      stdioTrace(
        "close: the operating system says the peer exited after " &
        $(Moment.now() - started).milliseconds & "ms"
      )
    try:
      if await waiter.withTimeout(PeerExitPollInterval):
        break
    except CancelledError:
      break

  try:
    let code = await waiter
    client.peerExitCode = Opt.some(code)
    let elapsed = Moment.now() - started

    if exitSeenAt.isSome() and Moment.now() - exitSeenAt.get() >= PeerExitNotifyGrace:
      # The peer was already gone and the event loop went on waiting for it -
      # so the timeout above killed a process that had exited long before.
      error "Peer exited well before the event loop was notified",
        remote = client.remote, exitCode = code,
        exitedAfter = exitSeenAt.get() - started, notifiedAfter = elapsed
    elif elapsed >= timeout:
      # `waitForExit` kills the peer once the timeout elapses and then reports
      # whatever status that produced - it does not report the timeout itself.
      error "Peer had to be killed: it never exited after its standard input " &
        "was closed", remote = client.remote, timeout, exitCode = code
      stdioTrace("close: the peer outlasted the timeout and was killed, code=" & $code)
    else:
      stdioTrace("close: the peer exited with " & $code)
  except AsyncProcessError, CancelledError:
    stdioTrace("close: gave up waiting for the peer")

method close*(client: RpcStdioClient) {.async: (raises: []).} =
  ## Close the connection and, if this client spawned the peer, wait for it to
  ## exit. The child sees end of file on its standard input, which is how a
  ## well behaved server is asked to shut down.
  ##
  ## A peer that does not take the hint is killed after `peerExitTimeout`
  ## rather than waited on forever: a peer that will not exit is a bug, and it
  ## is worth a great deal to have it show up as one failed call with a
  ## diagnosis attached instead of a whole test run that never finishes.
  if client.loop != nil:
    stdioTrace("close: cancelling the message loop")
    let loop = move(client.loop)
    await loop.cancelAndWait()
    stdioTrace("close: the message loop has stopped")

  if client.process != nil:
    let
      process = move(client.process)
      timeout =
        if client.peerExitTimeout <= ZeroDuration:
          DefaultPeerExitTimeout
        else:
          client.peerExitTimeout

    stdioTrace(
      "close: waiting up to " & $timeout.milliseconds & "ms for the peer to exit"
    )
    await client.awaitPeerExit(process, timeout)

    await process.closeWait()
    stdioTrace("close: done")

proc failure*(client: RpcStdioClient): ref JsonRpcError =
  client.lastFailure

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
