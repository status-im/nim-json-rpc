import
  strutils,
  streams,
  faststreams/async_backend,
  asynctools/asyncpipe,
  faststreams/inputs,
  faststreams/textio,
  parseutils,
  faststreams/asynctools_adapters,
  ./json_rpc/[server, client]

export jsonmarshal, router, server

type
  StreamClient* = ref object of RpcClient
    output*: AsyncOutputStream
  StreamConnection* = ref object of RpcServer
    output*: AsyncOutputStream
    client*: StreamClient
  Handler[T, U] = proc(input: T): Future[U] {.gcsafe, raises: [Defect, CatchableError, Exception].}
  HandlerWithId[T, U] = proc(input: T, id: int): Future[U] {.gcsafe, raises: [Defect, CatchableError, Exception].}
  NotificationHandler[T] = proc(input: T): Future[void] {.gcsafe, raises: [Defect, CatchableError, Exception].}

proc extractId  (id: JsonNode): int =
  if id.kind == JInt:
    result = id.getInt
  if id.kind == JString:
    discard parseInt(id.getStr, result)

proc wrapJsonRpcResponse(s: string): string =
  result = s & "\r\n"
  result = "Content-Length: " & $s.len & "\r\n\r\n" & s

proc wrap[T, Q](callback: Handler[T, Q]): RpcProc =
  return
    proc(input: JsonNode): Future[RpcResult] {.async} =
      let res = await callback(to(input{"params"}, T))
      return some(StringOfJson($(%res)))

proc wrap[T, Q](callback: HandlerWithId[T, Q]): RpcProc =
  return
    proc(input: JsonNode): Future[RpcResult] {.async} =
      let id = input{"id"}.extractId
      let params = input{"params"}
      return some(StringOfJson($(%(await callback(to(params, T), id)))))

proc wrap[T](callback: NotificationHandler[T]): RpcProc =
  return
    proc(input: JsonNode): Future[RpcResult] {.async} =
      await callback(to(input{"params"}, T))
      return none[StringOfJson]()

proc register*[T, Q](server: RpcServer, name: string, rpc: Handler[T, Q]) =
  server.register(name, wrap(rpc))

proc register*[T, Q](server: RpcServer, name: string, rpc: HandlerWithId[T, Q]) =
  server.register(name, wrap(rpc))

proc registerNotification*[T](server: RpcServer, name: string, rpc: NotificationHandler[T]) =
  server.register(name, wrap(rpc))

method call*(self: StreamClient,
             name: string,
             params: JsonNode): Future[Response] {.async} =
  ## Remotely calls the specified RPC method.
  let
    id = self.getNextId()
    value = wrapJsonRpcResponse($rpcCallNode(name, params, id))
    # completed by processMessage.
    newFut = newFuture[Response]()

  # add to awaiting responses
  self.awaiting[id] = newFut

  write(OutputStream(self.output), value)
  flush(self.output)
  return await newFut

proc call*(connection: StreamConnection, name: string,
          params: JsonNode): Future[Response] {.gcsafe, raises: [Exception].} =
  return connection.client.call(name, params)

proc notify*(connection: StreamConnection, name: string,
             params: JsonNode): Future[void] {.async.} =
  let value = wrapJsonRpcResponse($rpcNotificationNode(name, params))
  write(OutputStream(connection.output), value)
  flush(connection.output)

proc readMessage*(input: AsyncInputStream): Future[Option[string]] {.async.} =
  var
    contentLen = -1
    headerStarted = false

  while input.readable:
    let ln = await input.readLine()
    if ln.len != 0:
      let sep = ln.find(':')
      if sep == -1:
        continue
      let valueStart = skipWhitespace(ln, sep + 1) + sep + 1
      case ln[0 ..< sep]
      of "Content-Type":
        if ln.find("utf-8", valueStart) == -1 and ln.find("utf8", valueStart) == -1:
          raise newException(Exception, "only utf-8 is supported")
      of "Content-Length":
        if parseInt(ln, contentLen, valueStart) == 0:
          raise newException(Exception, "invalid Content-Length: " &
            ln.substr(valueStart))
      else:
        continue
      headerStarted = true
    elif not headerStarted:
      continue
    else:
      if contentLen != -1:
        if input.readable(contentLen):
           return some(cast[string](`@`(input.read(contentLen))))
        else:
           return none[string]();
  return none[string]();

proc start*[T](conn: StreamConnection, input: T): Future[void] {.async} =
  try:
    var message = await readMessage(input);
    while message.isSome:
      let json = parseJson(message.get);
      if (json{"result"}.isNil and json{"error"}.isNil):
        proc cb(fut: Future[RpcResult]) {.gcsafe.} =
          let res = fut.read
          if res.isSome:
            let resultMessage = wrapJsonRpcResponse(string(res.get));
            write(OutputStream(conn.output), resultMessage);
            flush(OutputStream(conn.output))
        route(conn, message.get).addCallback(cb);
      else:
        conn.client.processMessage(message.get)
      message = await readMessage(input);
  except IOError:
    return

proc new*(T: type StreamConnection, output: AsyncPipe, fullParams = true): T =
  let asyncOutput =  asyncPipeOutput(pipe = output, allowWaitFor = true);
  result = T(output: asyncOutput, client: StreamClient(output: asyncOutput))
  result.router.fullParams = fullParams

proc new*(T: type StreamConnection, output: AsyncOutputStream, fullParams = true): T =
  result.router.fullParams = fullParams
  return T(output: output, client: StreamClient(output: output))
