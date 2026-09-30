# ANCHOR: All
# pipes_server_client.nim

{.push gcsafe, raises: [].}

import std/oserrors
import chronos/osutils
import json_rpc/[rpcclient, rpcserver]
import ./rpc_format

createRpcSigsFromNim(RpcClient, RpcConv):
  proc hello(input: string): string

proc newPipe(): tuple[read, write: StreamTransport] =
  ## A pipe with both ends as transports
  const flags = {DescriptorFlag.NonBlock, DescriptorFlag.CloseOnExec}
  let pipe = createOsPipe(flags, flags).valueOr:
    raiseAssert "Unable to create a pipe: " & osErrorMsg(error)
  let
    read = fromPipe2(AsyncFD(pipe.read)).valueOr:
      raiseAssert "Unable to create a pipe: " & osErrorMsg(error)
    write = fromPipe2(AsyncFD(pipe.write)).valueOr:
      raiseAssert "Unable to create a pipe: " & osErrorMsg(error)
  (read, write)

proc main() {.async: (raises: [CancelledError, JsonRpcError]).} =
  # A pipe in each direction; here both ends live in this process
  let
    srvPipe = newPipe()
    clientPipe = newPipe()

  let srv = newRpcPipesServer(framing = Framing.httpHeader())
  srv.rpc(RpcConv):
    proc hello(input: string): string =
      "Hello " & input

  # ANCHOR: ServerPipes
  srv.start(srvPipe.read, clientPipe.write)
  # ANCHOR_END: ServerPipes
  defer: await srv.closeWait()

  # ANCHOR: ClientPipes
  let client = newRpcPipesClient(framing = Framing.httpHeader())
  client.connect(clientPipe.read, srvPipe.write)
  # ANCHOR_END: ClientPipes
  defer: await client.close()

  let resp = await client.hello("Daisy")
  doAssert resp == "Hello Daisy"

when isMainModule:
  waitFor main()
  echo "ok"

# ANCHOR_END: All
