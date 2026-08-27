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
  chronos/[asyncproc, osutils],
  ./pipesclient,
  ../[errors, router]

export pipesclient, asyncproc

# XXX workaround https://github.com/status-im/nim-chronos/pull/729
when defined(windows):
  import chronos/osdefs

type
  RpcStdioClient* = ref object of RpcPipesClient
    ## Bidirectional connection over standard input and output
    process*: AsyncProcessRef
    peerExitCode: Opt[int]

proc new*(
    T: type RpcStdioClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(RpcRouterCallback),
    framing = Framing.httpHeader(),
): T =
  T(maxMessageSize: maxMessageSize, router: router, framing: framing)

proc new*(
    T: type RpcStdioClient,
    maxMessageSize = defaultMaxMessageSize,
    router = default(ref RpcRouter),
    framing = Framing.httpHeader(),
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
    framing = Framing.httpHeader(),
): RpcStdioClient =
  ## Creates a new client instance.
  RpcStdioClient.new(maxMessageSize, router, framing)

# ---------------------------------------------------------------------------
# Connecting
# ---------------------------------------------------------------------------

# XXX workaround https://github.com/status-im/nim-chronos/pull/729
proc closePipeEnd(fd: AsyncFD) =
  when defined(windows):
    discard closeFd(HANDLE(fd))
  else:
    discard closeFd(cint(fd))

proc peerStdinPipe(): tuple[ours: StreamTransport, theirs: AsyncFD] {.raises: [JsonRpcError].} =
  const
    theirEnd: set[DescriptorFlag] = {}
    ourEnd = {DescriptorFlag.NonBlock, DescriptorFlag.CloseOnExec}
  let pipe = createOsPipe(theirEnd, ourEnd).valueOr:
    raise (ref RpcTransportError)(
      msg: "Unable to create the peer's standard input pipe: " & osErrorMsg(error)
    )
  let ours = fromPipe2(AsyncFD(pipe.write)).valueOr:
    closePipeEnd(AsyncFD(pipe.read))
    closePipeEnd(AsyncFD(pipe.write))
    raise (ref RpcTransportError)(
      msg: "Unable to use the peer's standard input pipe: " & osErrorMsg(error)
    )
  (ours: ours, theirs: AsyncFD(pipe.read))

proc connect*(
    client: RpcStdioClient,
    command: string,
    arguments: seq[string] = @[],
    workingDir = "",
    environment: StringTableRef = nil,
    options: set[AsyncProcessOption] = {},
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if client.process != nil:
    raise (ref RpcTransportError)(
      msg: "The client is already connected to a peer, close it first"
    )
  client.peerExitCode = Opt.none(int)
  let (ourStdin, theirStdin) = peerStdinPipe()

  let process =
    try:
      await startProcess(
        command,
        workingDir = workingDir,
        arguments = arguments,
        environment = environment,
        options = options,
        stdinHandle = ProcessStreamHandle.init(theirStdin),
        stdoutHandle = AsyncProcess.Pipe,
      )
    except AsyncProcessError as exc:
      closePipeEnd(theirStdin)
      await ourStdin.closeWait()
      raise (ref RpcTransportError)(msg: exc.msg, parent: exc)
    except CancelledError as exc:
      closePipeEnd(theirStdin)
      await ourStdin.closeWait()
      raise exc

  closePipeEnd(theirStdin)

  client.process = process
  client.loop = client.attach(process.stdoutStream.tsource, ourStdin, command)

method close*(client: RpcStdioClient) {.async: (raises: []).} =
  ## Closes the peer's standard input and waits for the peer to exit, which
  ## may take forever. Cancel it (ex: with `withTimeout`) to kill the peer.
  await procCall RpcPipesClient(client).close()

  if client.process != nil:
    let process = move(client.process)
    try:
      client.peerExitCode = Opt.some(await process.waitForExit(InfiniteDuration))
    except CancelledError:
      discard process.kill()
    except AsyncProcessError:
      discard
    await process.closeWait()

proc exitCode*(client: RpcStdioClient): Opt[int] =
  ## Exit code of the peer started by `connect`, or none while it is still
  ## running (or if no peer was started).
  if client.peerExitCode.isSome():
    client.peerExitCode
  elif client.process == nil or client.process.running().valueOr(true):
    Opt.none(int)
  else:
    let res = client.process.peekExitCode()
    if res.isOk():
      Opt.some(res.get())
    else:
      Opt.none(int)
