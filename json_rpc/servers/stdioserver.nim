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
  chronicles,
  chronicles/options,
  chronos,
  chronos/[osutils],
  ../errors,
  ./pipesserver

export pipesserver

when defined(windows):
  import chronos/osdefs

  when not compileOption("threads"):
    {.error: "the stdio transport needs --threads:on on Windows".}

proc logsToStdout(): bool {.compileTime.} =
  for stream in config.streams:
    for sink in stream.sinks:
      for destination in sink.destinations:
        if destination.kind == OutputDeviceKind.oStdOut:
          return true
  false

when loggingEnabled and logsToStdout():
  {.error: "stdio transport requires chronicles log to stderr; ex: `-d:chronicles_default_output_device=stderr`".}

logScope:
  topics = "jsonrpc server stdio"

# The standard input and output can only be served once
var stdioStarted = false

type RpcStdioServer* = ref object of RpcPipesServer

proc new*(
    T: type RpcStdioServer,
    maxMessageSize = defaultMaxMessageSize,
    framing = Framing.httpHeader(),
): T =
  T(
    router: RpcRouter.init(),
    maxMessageSize: maxMessageSize,
    framing: framing,
    processClientHook: processClient,
  )

proc newRpcStdioServer*(
    maxMessageSize = defaultMaxMessageSize, framing = Framing.httpHeader()
): RpcStdioServer =
  RpcStdioServer.new(maxMessageSize, framing)

proc newRpcStdioServer*(
    processClientHook: RpcProcessClient,
    maxMessageSize = defaultMaxMessageSize,
    framing = Framing.httpHeader(),
): RpcStdioServer =
  ## Create new server with custom processClientHook.
  result = RpcStdioServer.new(maxMessageSize, framing)
  result.processClientHook = processClientHook

when defined(windows):
  const BridgeBufSize = 8192

  type PumpCtx = object
    src, dst: HANDLE

  var
    stdinPump: Thread[PumpCtx]
    stdoutPump: Thread[PumpCtx]

  proc pump(ctx: PumpCtx) {.thread.} =
    defer:
      discard closeHandle(ctx.dst)
    var buf {.noinit.}: array[BridgeBufSize, byte]
    while true:
      var count = DWORD(0)
      if readFile(ctx.src, addr buf[0], DWORD(len(buf)), addr count, nil) == FALSE:
        return
      elif count == 0:
        return
      else:
        var sent = 0
        while sent < int(count):
          var written = DWORD(0)
          let ok = writeFile(
            ctx.dst, addr buf[sent], DWORD(int(count) - sent), addr written, nil
          )
          if ok == FALSE or written == 0:
            return
          sent += int(written)

  proc stdioTransports(): tuple[input, output: StreamTransport] {.raises: [JsonRpcError]} =
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

    let
      input = fromPipe2(AsyncFD(inPipe.read)).valueOr:
        raise (ref RpcTransportError)(
          msg: "Unable to use the standard input bridge: " & osErrorMsg(error)
        )
      output = fromPipe2(AsyncFD(outPipe.write)).valueOr:
        raise (ref RpcTransportError)(
          msg: "Unable to use the standard output bridge: " & osErrorMsg(error)
        )
    (input, output)

  proc joinStdout() =
    if stdoutPump.running():
      joinThread(stdoutPump)

else:
  proc stdioTransports(): tuple[input, output: StreamTransport] {.raises: [JsonRpcError]} =
    let
      inFd = AsyncFD(0)
      outFd = AsyncFD(1)
    for fd in [cint(0), cint(1)]:
      setDescriptorBlocking(fd, false).isOkOr:
        raise (ref RpcTransportError)(
          msg: "Unable to switch standard descriptor " & $fd &
            " to non-blocking mode: " & osErrorMsg(error)
        )

    let
      input = fromPipe2(inFd).valueOr:
        raise (ref RpcTransportError)(
          msg: "Unable to use the standard input: " & osErrorMsg(error)
        )
      output = fromPipe2(outFd).valueOr:
        raise (ref RpcTransportError)(
          msg: "Unable to use the standard output: " & osErrorMsg(error)
        )
    (input, output)

  proc joinStdout() =
    discard

proc start*(server: RpcStdioServer) {.raises: [JsonRpcError].} =
  if stdioStarted:
    raise (ref RpcBindError)(
      msg: "The standard input and output have already been served"
    )
  stdioStarted = true

  let (input, output) = stdioTransports()
  info "Starting JSON-RPC stdio server"
  server.start(input, output)

proc serve*(
    server: RpcStdioServer
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if server.loop == nil:
    server.start()

  try:
    await RpcPipesServer(server).serve()
  finally:
    joinStdout()
