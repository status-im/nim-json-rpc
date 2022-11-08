import
  unittest,
  websock/websock,
  ../json_rpc/[rpcclient, rpcserver]

const
  serverHost    = "localhost"
  serverPort    = 8547
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
    waitFor client.connect(serverHost, Port(serverPort), false)
    expect ErrorResponse:
      let r = waitFor client.call("testHook", %[%"abc"])

  test "good auth token":
    let client = newRpcHttpClient(getHeaders = authHeaders)
    waitFor client.connect(serverHost, Port(serverPort), false)
    let r = waitFor client.call("testHook", %[%"abc"])
    check r.getStr == "Hello abc"

  waitFor srv.closeWait()

proc wsAuthHeaders(ctx: Hook,
                  headers: var HttpTable): Result[void, string]
                  {.gcsafe, raises: [Defect].} =
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
    "127.0.0.1",
    Port(8545),
    authHooks = @[WsAuthHook(mockAuth)]
  )
  srv.setupServer()
  srv.start()
  let client = newRpcWebSocketClient()

  test "no auth token":
    try:
      waitFor client.connect("ws://127.0.0.1:8545/")
      check false
    except CatchableError as e:
      check e.msg == "Server did not reply with a websocket upgrade: Header code: 403 Header reason: Forbidden Address: 127.0.0.1:8545"

  test "good auth token":
    waitFor client.connect("ws://127.0.0.1:8545/", hooks = @[hook])
    let r = waitFor client.call("testHook", %[%"abc"])
    check r.getStr == "Hello abc"

  srv.stop()
  waitFor srv.closeWait()
