# ANCHOR: All
# stdio_client.nim

{.push gcsafe, raises: [].}

import std/[os, osproc]
import json_rpc/clients/stdioclient
import ./rpc_format

const serverPath = currentSourcePath().parentDir() / "stdio_server"

createRpcSigsFromNim(RpcClient, RpcConv):
  proc hello(input: string): string

proc main() {.async: (raises: [CancelledError, JsonRpcError]).} =
  let peerExe = serverPath.addFileExt(ExeExt)

  # ANCHOR: ClientConnect
  const framing = Framing.httpHeader()
  let client = newRpcStdioClient(framing = framing)
  await client.connect(peerExe)
  # ANCHOR_END: ClientConnect

  let resp = await client.hello("Daisy")
  doAssert resp == "Hello Daisy"

  # ANCHOR: ClientDisconnect
  await client.close()
  doAssert client.exitCode() == Opt.some(0)
  # ANCHOR_END: ClientDisconnect

proc buildStdioServer() =
  const mode =
    when defined(release):
      "-d:release"
    elif defined(danger):
      "-d:danger"
    else:
      ""
  const flags = "--threads:on -d:chronicles_log_level=ERROR -d:\"chronicles_sinks=textlines[stderr]\""
  let res = try:
    execCmdEx("nim c " & mode & " " & flags & " " & serverPath)
  except CatchableError as err:
    raiseAssert "Failed to build server: " & err.msg
  doAssert res.exitCode == 0, "Failed to build server: " & res.output

when isMainModule:
  buildStdioServer()
  waitFor main()
  echo "ok"

# ANCHOR_END: All
