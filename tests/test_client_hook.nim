# json-rpc
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/importutils,
  unittest2,
  chronicles,
  websock/websock,
  ../json_rpc/rpcclient,
  ../json_rpc/rpcserver

createRpcSigsFromNim(RpcClient):
  proc get_Banana(id: int): int

proc installHandlers(s: RpcServer) =
  s.rpc("get_Banana") do(id: int) -> JsonString:
    if id == 99:
      return "123".JsonString
    elif id == 100:
      return "\"stop\"".JsonString
    else:
      return "\"error\"".JsonString

type
  Shadow = ref object
    something: int

proc setupClientHook(client: RpcClient): Shadow =
  var shadow = Shadow(something: 0)
  client.onProcessMessage = proc(client: RpcClient, line: string):
                                Result[bool, string] {.gcsafe, raises: [].} =

     try:
       let m = JrpcConv.decode(line, JsonNode)
       if m["result"].kind == JString:
           if m["result"].str == "stop":
             shadow.something = 123
             return ok(false)
           else:
             shadow.something = 77
             return err("not stop")

       return ok(true)
     except CatchableError as exc:
      return err(exc.msg)
  shadow

suite "test client features":
  var server = newRpcHttpServer(["127.0.0.1:0"])
  server.installHandlers()
  var client = newRpcHttpClient()
  let shadow = client.setupClientHook()

  server.start()
  waitFor client.connect("http://" & $server.localAddress()[0])

  test "client onProcessMessage hook":
    let res = waitFor client.get_Banana(99)
    check res == 123
    check shadow.something == 0

    expect JsonRpcError:
      let res2 = waitFor client.get_Banana(123)
      check res2 == 0
    check shadow.something == 77

    expect InvalidResponse:
      let res2 = waitFor client.get_Banana(100)
      check res2 == 0
    check shadow.something == 123

  waitFor server.stop()
  waitFor server.closeWait()


type
  TestSocketServer = ref object of RpcSocketServer
    getData: proc(): string {.gcsafe, raises: [].}

proc processClient(server: StreamServer, transport: StreamTransport) {.async: (raises: []), gcsafe.} =
  ## Process transport data to the RPC server
  try:
    var rpc = getUserData[TestSocketServer](server)
    while true:
      var
        value = await transport.readLine(router.defaultMaxRequestLength)
      if value == "":
        await transport.closeWait()
        break

      let res = rpc.getData()
      discard await transport.write(res & "\r\n")
  except TransportError as ex:
    error "Transport closed during processing client", msg=ex.msg
  except CatchableError as ex:
    error "Error occured during processing client", msg=ex.msg

proc addStreamServer(server: TestSocketServer, address: TransportAddress) =
  privateAccess(RpcSocketServer)
  try:
    info "Starting JSON-RPC socket server", address = $address
    var transportServer = createStreamServer(address, processClient, {ReuseAddr}, udata = server)
    server.servers.add(transportServer)
  except CatchableError as exc:
    error "Failed to create server", address = $address, message = exc.msg

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc new(T: type TestSocketServer, getData: proc(): string {.gcsafe, raises: [].}): T =
  T(
    router: RpcRouter.init(),
    getData: getData,
  )


suite "test rpc socket client":
  let server = TestSocketServer.new(proc(): string {.gcsafe, raises: [].} =
     return """{"jsonrpc":"2.0","result":10}"""
  )
  let serverAddress = initTAddress("127.0.0.1:0")
  server.addStreamServer(serverAddress)

  var client = newRpcSocketClient()
  server.start()
  waitFor client.connect(server.localAddress()[0])

  test "missing id in server response":
    expect JsonRpcError:
      let res = waitFor client.get_Banana(11)
      discard res

  server.stop()
  waitFor server.closeWait()


type
  TestHttpServer = ref object of RpcHttpServer
    getData: proc(): string {.gcsafe, raises: [].}

proc processClientRpc(rpcServer: TestHttpServer): HttpProcessCallback2 =
  return proc (req: RequestFence): Future[HttpResponseRef]
                  {.async: (raises: [CancelledError]).} =
    if not req.isOk():
      return defaultResponse()

    let
      request = req.get()
      headers = HttpTable.init([("Content-Type",
                             "application/json; charset=utf-8")])
    try:
      let data = rpcServer.getData()
      let res = await request.respond(Http200, data, headers)
      trace "JSON-RPC result has been sent"
      return res
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "Internal error while processing JSON-RPC call"
      return defaultResponse(exc)

proc addHttpServer(
    rpcServer: TestHttpServer,
    address: TransportAddress,
    socketFlags: set[ServerFlags] = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
    serverUri = Uri(),
    serverIdent = "",
    maxConnections: int = -1,
    bufferSize: int = 4096,
    backlogSize: int = 100,
    httpHeadersTimeout = 10.seconds,
    maxHeadersSize: int = 8192,
    maxRequestBodySize: int = 1_048_576) =
  let server = HttpServerRef.new(
      address,
      processClientRpc(rpcServer),
      {},
      socketFlags,
      serverUri, "nim-json-rpc", maxConnections, backlogSize,
      bufferSize, httpHeadersTimeout, maxHeadersSize, maxRequestBodySize
      ).valueOr:
    error "Failed to create server", address = $address,
                                     message = error
    raise newException(RpcBindError, "Unable to create server: " & $error)
  info "Starting JSON-RPC HTTP server", url = "http://" & $address

  privateAccess(RpcHttpServer)
  rpcServer.httpServers.add server

proc new(T: type TestHttpServer, getData: proc(): string {.gcsafe, raises: [].}): T =
  T(
    router: RpcRouter.init(),
    maxChunkSize: 8192,
    getData: getData,
  )

suite "test rpc http client":
  let server = TestHttpServer.new(proc(): string {.gcsafe, raises: [].} =
     return """{"jsonrpc":"2.0","result":10}"""
  )
  let serverAddress = initTAddress("127.0.0.1:0")
  server.addHttpServer(serverAddress)

  var client = newRpcHttpClient()
  server.start()
  waitFor client.connect("http://" & $server.localAddress()[0])

  test "missing id in server response":
    expect JsonRpcError:
      let res = waitFor client.get_Banana(11)
      discard res

  waitFor server.stop()
  waitFor server.closeWait()


type
  TestWsServer = ref object of RpcWebSocketServer
    getData: proc(): string {.gcsafe, raises: [].}

proc handleRequest(rpc: TestWsServer, request: websock.HttpRequest)
                  {.async: (raises: [CancelledError]).} =
  try:
    let server = rpc.wsserver
    let ws = await server.handleRequest(request)
    if ws.readyState != ReadyState.Open:
      error "Failed to open websocket connection"
      return

    trace "Websocket handshake completed"
    while ws.readyState != ReadyState.Closed:
      let recvData = await ws.recvMsg()
      trace "Client message: ", size = recvData.len, binary = ws.binary

      if ws.readyState == ReadyState.Closed:
        # if session already terminated by peer,
        # no need to send response
        break

      if recvData.len == 0:
        await ws.close(
          reason = "cannot process zero length message"
        )
        break

      let data = rpc.getData()

      trace "RPC result has been sent", address = $request.uri
      await ws.send(data)

  except WebSocketError as exc:
    error "WebSocket error:", exception = exc.msg

  except CancelledError as exc:
    raise exc

  except CatchableError as exc:
    error "Something error", msg=exc.msg

proc newWsServer(address: TransportAddress, getData: proc(): string {.gcsafe, raises: [].}): TestWsServer =

  let flags = {ServerFlags.TcpNoDelay,ServerFlags.ReuseAddr}
  var server = new(TestWsServer)
  proc processCallback(request: websock.HttpRequest): Future[void] =
    handleRequest(server, request)

  privateAccess(RpcWebSocketServer)

  server.getData = getData
  server.wsserver = WSServer.new(rng = HmacDrbgContext.new())
  server.server = websock.HttpServer.create(
    address,
    processCallback,
    flags
  )

  server

suite "test ws http client":
  let serverAddress = initTAddress("127.0.0.1:0")
  let server = newWsServer(serverAddress, proc(): string {.gcsafe, raises: [].} =
     return """{"jsonrpc":"2.0","result":10}"""
  )

  var client = newRpcWebSocketClient()
  server.start()
  waitFor client.connect("ws://" & $server.localAddress())

  test "missing id in server response":
    expect JsonRpcError:
      let res = waitFor client.get_Banana(11)
      discard res

  server.stop()
  waitFor server.closeWait()
