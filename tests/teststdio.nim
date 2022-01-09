import
  strutils,
  faststreams/async_backend,
  asynctools/asyncpipe,
  faststreams/inputs,
  faststreams/textio,
  unittest,
  parseutils,
  faststreams/asynctools_adapters,
  ../json_rpc/[server, client]

type
  StreamClient* = ref object of RpcClient
    output*: AsyncPipe
  StreamConnection* = ref object of RpcServer
    input*: AsyncInputStream
    output*: AsyncPipe
    client*: StreamClient

proc wrapJsonRpcResponse(s: string): string =
  result = s & "\r\n"
  result = "Content-Length: " & $s.len & "\r\n\r\n" & s

method call*(self: StreamClient,
             name: string,
             params: JsonNode): Future[Response] {.async} =
  ## Remotely calls the specified RPC method.
  let id = self.getNextId()
  var value = wrapJsonRpcResponse($rpcCallNode(name, params, id))

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut

  let res = await self.output.write(value[0].addr, value.len)
  doAssert(res == len(value))
  return await newFut

proc call*(connection: StreamConnection, name: string,
          params: JsonNode): Future[Response] {.gcsafe, raises: [Exception].} =
  return connection.client.call(name, params)

proc skipWhitespace(x: string, pos: int): int =
  result = pos
  while result < x.len and x[result] in Whitespace:
    inc result

proc readMessage(input: AsyncInputStream): Future[Option[string]] {.async.} =
  var contentLen = -1
  var headerStarted = false
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
        discard conn.output.write(resultMessage[0].addr, resultMessage.len);
    else:
      conn.client.processMessage(message.get)

    message = await readMessage(conn.input);

proc new*(T: type StreamConnection, input: AsyncPipe, output: AsyncPipe): T =
  T(input: asyncPipeInput(input), output: output, client: StreamClient(output: output))


# for testing purposes
var cachedInput: JsonNode;

proc echo(params: JsonNode): Future[RpcResult] {.async,
    raises: [CatchableError, Exception].} =
  {.gcsafe.}:
    cachedInput = params;
  return some(StringOfJson($params))

suite "Client/server over JSONRPC":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let serverConnection = StreamConnection.new(pipeClient, pipeServer);
  serverConnection.router.register("echo", echo)
  discard serverConnection.start();

  let clientConnection = StreamConnection.new(pipeServer, pipeClient);
  discard clientConnection.start();

  test "Simple call.":
    let response = clientConnection.call("echo", %"input").waitFor().getStr
    doAssert (response == "input")
    doAssert (cachedInput.getStr == "input")

  echo "suite teardown: run once after the tests"
