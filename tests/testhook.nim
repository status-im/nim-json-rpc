# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2,
  websock/websock,
  ../json_rpc/[rpcclient, rpcserver]

const
  serverHost    = "127.0.0.1"
  serverPort    = 0 # let the OS choose the port
  serverAddress = serverHost & ":" & $serverPort

proc setupServer*(srv: RpcServer) =
  srv.rpc("testHook") do(input: string):
    return %("Hello " & input)

proc authHeaders(): seq[(string, string)] =
  @[("Auth-Token", "Good Token")]

suite "HTTP server hook test":
  proc mockAuth(req: HttpRequestRef): Future[HttpResponseRef] {.async.} =
    if req.headers.getString("Auth-Token") == "Good Token":
      return HttpResponseRef(nil)

    return await req.respond(Http401, "Unauthorized access")

  let srv = newRpcHttpServer([serverAddress], @[HttpAuthHook(mockAuth)])
  srv.setupServer()
  srv.start()

  test "no auth token":
    let client = newRpcHttpClient()
    waitFor client.connect("http://" & $srv.localAddress()[0])
    expect ErrorResponse:
      let r = waitFor client.call("testHook", %[%"abc"])
      discard r

  test "good auth token":
    let client = newRpcHttpClient(getHeaders = authHeaders)
    waitFor client.connect("http://" & $srv.localAddress()[0])
    let r = waitFor client.call("testHook", %[%"abc"])
    check r.string == "\"Hello abc\""

  waitFor srv.closeWait()

proc wsAuthHeaders(ctx: Hook,
                  headers: var HttpTable): Result[void, string]
                  {.gcsafe, raises: [].} =
  headers.add("Auth-Token", "Good Token")
  return ok()

suite "Websocket server hook test":
  let hook = Hook(append: wsAuthHeaders)

  proc mockAuth(req: websock.HttpRequest): Future[bool] {.async.} =
    if not req.headers.contains("Auth-Token"):
      await req.sendResponse(code = Http403, data = "Missing Auth-Token")
      return false

    let token = req.headers.getString("Auth-Token")
    if token != "Good Token":
      await req.sendResponse(code = Http401, data = "Unauthorized access")
      return false

    return true

  let srv = newRpcWebSocketServer(
    serverHost,
    Port(serverPort),
    authHooks = @[WsAuthHook(mockAuth)]
  )
  srv.setupServer()
  srv.start()
  let client = newRpcWebSocketClient()

  test "no auth token":
    try:
      waitFor client.connect("ws://" & $srv.localAddress())
      check false
    except CatchableError as e:
      check e.msg == "Server did not reply with a websocket upgrade: Header code: 403 Header reason: Forbidden Address: " & $srv.localAddress()

  test "good auth token":
    waitFor client.connect("ws://" & $srv.localAddress(), hooks = @[hook])
    let r = waitFor client.call("testHook", %[%"abc"])
    check r.string == "\"Hello abc\""

  srv.stop()
  waitFor srv.closeWait()
