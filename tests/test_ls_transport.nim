# json-rpc
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/tables,
  chronos/unittest2/asynctests,
  ../json_rpc/[servers/socketserver, clients/socketclient]

createJsonFlavor JsonLsp,
  automaticObjectSerialization = true,
  automaticPrimitivesSerialization = true

const
  RequestCancelled = -32800
  MaxIdStringLength = 256
  Timeout = 10.seconds

type
  Rpc = proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises: [].}

  PendingState = enum
    psOnGoing
    psComplete

  PendingRequest = object
    id: RequestId
    name: string
    state: PendingState
    request: FutureBase

  LanguageServer = ref object
    srv: RpcSocketServer
    client: RpcSocketClient
    pendingRequests: Table[RequestId, PendingRequest]
    signal: Future[void]

  EchoParams = object
    value*: string

  CancelParams = object
    id*: RequestId

proc readValue(
    r: var JsonLsp.Reader, val: var RequestId
) {.gcsafe, raises: [IOError, JsonReaderError].} =
  let tok = r.tokKind
  case tok
  of JsonValueKind.Number:
    val = RequestId(kind: riNumber, num: r.parseInt(int))
  of JsonValueKind.String:
    val = RequestId(kind: riString, str: r.parseString(MaxIdStringLength))
  else:
    r.raiseUnexpectedValue("Invalid RequestId, must be Number or String, got=" & $tok)

proc writeValue(
    w: var JsonLsp.Writer, val: RequestId
) {.gcsafe, raises: [IOError].} =
  case val.kind
  of riNumber: w.writeValue val.num
  of riString: w.writeValue val.str
  of riNull: w.writeValue JsonString("null")

func toJson(params: RequestParamsRx): string =
  if params.kind == rpPositional:
    doAssert params.positional.len == 0
    "{}"
  else:
    JrpcSys.encode(params.toTx)

func toParams(params: JsonString): Result[RequestParamsTx, string] =
  try:
    ok JrpcSys.decode(params, RequestParamsRx).toTx
  except CatchableError as ex:
    err ex.msg

proc wrapRpc[T](fn: proc(params: T): Future[auto] {.gcsafe, raises: [].}): Rpc =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.} =
    let val = JsonLsp.decode(params.toJson, T)
    try:
      when typeof(fn(val)) is Future[void]:
        await fn(val)
        return JsonString("null")
      else:
        let res = await fn(val)
        return JsonString(JsonLsp.encode(res))
    except CancelledError:
      raise (ref ApplicationError)(
        code: RequestCancelled, msg: "Request cancelled"
      )

proc trackRequest(
    ls: LanguageServer, request: RequestBatchRx, fut: FutureBase
) {.raises: [].} =
  if request.kind != rbkSingle:
    return
  let req = request.single
  let id = req.id.valueOr:
    return
  if id.kind == riNull:
    return

  ls.pendingRequests[id] =
    PendingRequest(id: id, name: req.meth, state: psOnGoing, request: fut)

  fut.addCallback proc(_: pointer) =
    try:
      ls.pendingRequests[id].state = psComplete
    except KeyError:
      discard

proc cancelRequest(ls: LanguageServer, id: RequestId) =
  let pending = ls.pendingRequests.getOrDefault(id)
  if pending.request.isNil or pending.state == psComplete:
    return
  pending.request.cancelSoon()

proc respond(
    ls: LanguageServer, conn: RpcSocketClient, handled: Future[seq[byte]].Raising([])
) {.async: (raises: []).} =
  let res =
    try:
      await handled
    except CancelledError:
      return
  if res.len == 0:
    return
  try:
    await conn.send(res)
  except CancelledError:
    discard
  except JsonRpcError:
    discard

proc route(
    ls: LanguageServer, conn: RpcSocketClient, request: RequestBatchRx
): Future[seq[byte]] {.async: (raises: [], raw: true).} =
  let handled = ls.srv.router.route(request)
  ls.trackRequest(request, handled)
  asyncSpawn ls.respond(conn, handled)

  result = Future[seq[byte]].Raising([]).init(
    "lstransport.route", {FutureFlag.OwnCancelSchedule}
  )
  result.complete(default(seq[byte]))

proc processClient(
    ls: LanguageServer, server: StreamServer, transport: StreamTransport
) {.async: (raises: []), gcsafe.} =
  let remote = transport.remoteAddress2().valueOr(default(TransportAddress))
  var client: RpcSocketClient
  client = RpcSocketClient.new(
    framing = Framing.httpHeader(),
    router = proc(
        request: RequestBatchRx
    ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
      ls.route(client, request),
  )

  ls.srv.connections.incl(client)
  ls.client = client

  await client.attach(transport, $remote)

  ls.srv.connections.excl(client)
  if ls.client == client:
    ls.client = nil

proc notify(ls: LanguageServer, name: string, params: JsonString) =
  let client = ls.client
  if client.isNil:
    return
  let reqParams = params.toParams.valueOr:
    return

  proc send() {.async: (raises: []).} =
    try:
      await client.notify(name, reqParams)
    except CancelledError, JsonRpcError:
      discard

  asyncSpawn send()

proc call(
    ls: LanguageServer, name: string, params: JsonString
): Future[JsonString] =
  let client = ls.client
  if client.isNil:
    let fut = newFuture[JsonString]("ls.call")
    fut.fail newException(JsonRpcError, "No client connected")
    return fut
  let reqParams = params.toParams.valueOr:
    let fut = newFuture[JsonString]("ls.call")
    fut.fail newException(JsonRpcError, "Cannot encode the request params: " & error)
    return fut
  client.call(name, reqParams)

proc initSocketServer(ls: LanguageServer) =
  ls.srv = newRpcSocketServer(
    proc(
        server: StreamServer, transport: StreamTransport
    ): Future[void] {.async: (raises: [], raw: true).} =
      ls.processClient(server, transport)
  )

  ls.srv.router.register(
    "slow",
    wrapRpc(
      proc(params: EchoParams): Future[string] {.async.} =
        await ls.signal
        "slow " & params.value
    ),
  )
  ls.srv.router.register(
    "fast",
    wrapRpc(
      proc(params: EchoParams): Future[string] {.async.} =
        "fast " & params.value
    ),
  )
  ls.srv.router.register(
    "$/cancelRequest",
    wrapRpc(
      proc(params: CancelParams): Future[void] {.async.} =
        ls.cancelRequest(params.id)
    ),
  )

proc startSocketServer(ls: LanguageServer): Port {.raises: [JsonRpcError].} =
  ls.srv.addStreamServer("127.0.0.1", Port(0))
  ls.srv.start()
  ls.srv.localAddress()[0].port

proc waitUntilConnected(ls: LanguageServer) {.async.} =
  while ls.client.isNil:
    await sleepAsync(0.milliseconds)

proc params(obj: auto): RequestParamsTx {.raises: [].} =
  JsonString(JsonLsp.encode(obj)).toParams.expect("params of an object")

proc pending(ls: LanguageServer, name: string): PendingRequest =
  for req in ls.pendingRequests.values:
    if req.name == name:
      doAssert result == default(PendingRequest)
      result = req

proc waitUntilPending(ls: LanguageServer, name: string) {.async.} =
  while ls.pending(name).request.isNil:
    await sleepAsync(0.milliseconds)

suite "Language server style socket transport":
  setup:
    var ls = LanguageServer(signal: newFuture[void]("signal"))
    ls.initSocketServer()
    let port = ls.startSocketServer()

    let notified = newFuture[string]("notified")
    var clientRouter = new(RpcRouter)
    clientRouter[] = RpcRouter.init()
    clientRouter[].register(
      "window/showMessage",
      wrapRpc(
        proc(params: EchoParams): Future[void] {.async.} =
          notified.complete(params.value)
      ),
    )
    clientRouter[].register(
      "workspace/applyEdit",
      wrapRpc(
        proc(params: EchoParams): Future[string] {.async.} =
          "applied " & params.value
      ),
    )

    var client =
      newRpcSocketClient(router = clientRouter, framing = Framing.httpHeader())
    waitFor client.connect("127.0.0.1", port)
    waitFor ls.waitUntilConnected().wait(Timeout)

  teardown:
    if not ls.signal.finished():
      ls.signal.complete()
    waitFor client.close()
    ls.srv.stop()
    waitFor ls.srv.closeWait()

  test "Handlers run concurrently":
    let slow = client.call("slow", params(EchoParams(value: "one")))
    let fast = waitFor client.call("fast", params(EchoParams(value: "two"))).wait(Timeout)
    check:
      fast == JsonString(""""fast two"""")
      not slow.finished()

    ls.signal.complete()
    check (waitFor slow.wait(Timeout)) == JsonString(""""slow one"""")

  test "In-flight requests are tracked":
    let slow = client.call("slow", params(EchoParams(value: "one")))
    waitFor ls.waitUntilPending("slow").wait(Timeout)
    check:
      ls.pending("slow").state == psOnGoing
      ls.pending("slow").id.kind == riNumber

    ls.signal.complete()
    discard waitFor slow.wait(Timeout)
    check ls.pending("slow").state == psComplete

  test "Notifications are not tracked":
    waitFor client.notify(
      "$/cancelRequest", params(CancelParams(id: RequestId(kind: riNumber, num: 123)))
    )
    let fast = waitFor client.call("fast", params(EchoParams(value: "two"))).wait(Timeout)
    check:
      fast == JsonString(""""fast two"""")
      ls.pendingRequests.len == 1
      ls.pending("$/cancelRequest").request.isNil

  test "A request can be cancelled by id":
    let slow = client.call("slow", params(EchoParams(value: "one")))
    waitFor ls.waitUntilPending("slow").wait(Timeout)
    let id = ls.pending("slow").id

    waitFor client.notify("$/cancelRequest", params(CancelParams(id: id)))

    try:
      discard waitFor slow.wait(Timeout)
      check false
    except JsonRpcError as ex:
      check ex.msg == """{"code":-32800,"message":"Request cancelled"}"""
    check ls.pending("slow").state == psComplete

  test "Cancelling a request does not affect the others":
    let slow = client.call("slow", params(EchoParams(value: "one")))
    waitFor ls.waitUntilPending("slow").wait(Timeout)
    waitFor client.notify(
      "$/cancelRequest", params(CancelParams(id: ls.pending("slow").id))
    )
    expect JsonRpcError:
      discard waitFor slow.wait(Timeout)

    let fast = waitFor client.call("fast", params(EchoParams(value: "two"))).wait(Timeout)
    check fast == JsonString(""""fast two"""")

  test "Cancelling an unknown id is a no-op":
    waitFor client.notify(
      "$/cancelRequest", params(CancelParams(id: RequestId(kind: riNumber, num: 999)))
    )
    let fast = waitFor client.call("fast", params(EchoParams(value: "two"))).wait(Timeout)
    check fast == JsonString(""""fast two"""")

  test "The server notifies the connected client":
    ls.notify("window/showMessage", JsonString("""{"value":"hello"}"""))
    check (waitFor notified.wait(Timeout)) == "hello"

  test "The server calls the connected client":
    let res = waitFor ls.call(
      "workspace/applyEdit", JsonString("""{"value":"edit"}""")
    ).wait(Timeout)
    check res == JsonString(""""applied edit"""")

  test "The server calls the client while a request is in flight":
    let slow = client.call("slow", params(EchoParams(value: "one")))
    waitFor ls.waitUntilPending("slow").wait(Timeout)

    let res = waitFor ls.call(
      "workspace/applyEdit", JsonString("""{"value":"edit"}""")
    ).wait(Timeout)
    check res == JsonString(""""applied edit"""")

    ls.signal.complete()
    check (waitFor slow.wait(Timeout)) == JsonString(""""slow one"""")

{.pop.}
