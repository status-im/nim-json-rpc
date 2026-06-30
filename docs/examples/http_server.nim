# ANCHOR: All
# http_server.nim

{.push gcsafe, raises: [].}

import json_rpc/rpcserver
import ./rpc_format

export rpcserver

proc setupServer(srv: RpcServer) =
  # ANCHOR: RpcHello
  srv.rpc(RpcConv):
    proc hello(input: string): string =
      "Hello " & input
  # ANCHOR_END: RpcHello

    # ANCHOR: RpcHowdy
    proc howdy(input: string): string {.async: (raises: []).} =
      "Howdy " & input
    # ANCHOR_END: RpcHowdy

    # ANCHOR: RpcBye
    proc bye(input {.serializedFieldName: "user-name".}: string): string =
      "Bye " & input
    # ANCHOR_END: RpcBye

    # ANCHOR: RpcEmoji
    proc `👑`(input: string): string =
      "👑 " & input
    # ANCHOR_END: RpcEmoji

    # ANCHOR: RpcEmpty
    proc empty(): void =
      echo "nothing"
    # ANCHOR_END: RpcEmpty

    proc justHello(): string =
      "Hello"

    # ANCHOR: RpcTeaPot
    proc teaPot(): void {.raises: [ApplicationError].} =
      raise (ref ApplicationError)(
        code: 418, data: Opt.none(JsonString), msg: "I'm a teapot"
      )
    # ANCHOR_END: RpcTeaPot

proc startServer*(): RpcHttpServer {.raises: [JsonRpcError].} =
  # ANCHOR: ServerConnect
  let srv = newRpcHttpServer(["127.0.0.1:0"])
  # ANCHOR_END: ServerConnect
  srv.setupServer()
  # ANCHOR: RpcHttpServerStart
  srv.start()
  # ANCHOR_END: RpcHttpServerStart
  srv

proc stopServer*(srv: RpcHttpServer) {.async: (raises: []).} =
  # ANCHOR: ServerDisconnect
  await srv.stop()
  await srv.closeWait()
  # ANCHOR_END: ServerDisconnect

proc main() {.raises: [JsonRpcError].} =
  let srv = startServer()
  runForever()

when isMainModule:
  main()

# ANCHOR_END: All
