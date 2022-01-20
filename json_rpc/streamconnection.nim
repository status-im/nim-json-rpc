import
  strutils,
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
    input*: AsyncInputStream
    output*: AsyncOutputStream
    client*: StreamClient

proc wrapJsonRpcResponse(s: string): string =
  result = s & "\r\n"
  result = "Content-Length: " & $s.len & "\r\n\r\n" & s

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

  # writeFile("/home/yyoncho/aa.txt", value)
  write(OutputStream(self.output), value)
  discard flushAsync(self.output)
  return await newFut


proc call*(connection: StreamConnection, name: string,
          params: JsonNode): Future[Response] {.gcsafe, raises: [Exception].} =
  return connection.client.call(name, params)

proc skipWhitespace(x: string, pos: int): int =
  result = pos
  while result < x.len and x[result] in Whitespace:
    inc result

proc readMessage(input: AsyncInputStream): Future[Option[string]] {.async.} =
  var
    contentLen = -1
    headerStarted = false

  while input.readable:
    let ln = await input.readLine()
    if ln.len != 0:
      let sep = ln.find(':')
      if sep == -1:
        continue

      let valueStart = skipWhitespace(ln, sep + 1)
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
        return some(cast[string](`@`(input.read(contentLen))))
      else:
        raise newException(Exception, "missing Content-Length header")
  return none[string]();

proc start*(conn: StreamConnection): Future[void] {.async} =
  var message = await readMessage(conn.input);

  while message.isSome:
    let json = parseJson(message.get);
    if (json{"result"}.isNil and json{"error"}.isNil):
      let res = await route(conn, message.get);
      if res.isSome:
        var resultMessage = wrapJsonRpcResponse(string(res.get));
        write(OutputStream(conn.output), string(resultMessage));
        discard flushAsync(conn.output)
    else:
      conn.client.processMessage(message.get)

    message = await readMessage(conn.input);

proc new*(T: type StreamConnection, input: AsyncPipe, output: AsyncPipe): T =
  let asyncOutput =  asyncPipeOutput(pipe = output, allowWaitFor = true);
  T(input: asyncPipeInput(input),
    output: asyncOutput,
    client: StreamClient(output: asyncOutput))

proc new*(T: type StreamConnection, input: AsyncInputStream, output: AsyncOutputStream): T =
  return T(input: input, output: output, client: StreamClient(output: output))
