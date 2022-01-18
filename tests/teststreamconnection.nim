import
  std/json,
  unittest,
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  ../json_rpc/streamconnection

# for testing purposes
var cachedInput: JsonNode;

proc echo(params: JsonNode): Future[RpcResult] {.async,
    raises: [CatchableError, Exception].} =
  {.gcsafe.}:
    cachedInput = params;
  return some(StringOfJson($params))

type
  DemoObject* = object
    foo*: int
    bar*: int

  Mapper[T, U] = proc(input: T): Future[U] {.gcsafe, raises: [Defect, CatchableError, Exception].}

proc wrap[T, Q](callback: Mapper[T, Q]): RpcProc =
  return
    proc(input: JsonNode): Future[RpcResult] {.async} =
      return some(StringOfJson($(%(await callback(to(input, T))))))

proc register*[T, Q](server: RpcServer, name: string, rpc: Mapper[T, Q]) =
  ## Add a name/code pair to the RPC server.
  server.register(name, wrap(rpc))

suite "Client/server over JSONRPC":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  proc echoDemoObject(params: DemoObject): Future[DemoObject] {.async,
      raises: [CatchableError, Exception].} =
    return params

  let serverConnection = StreamConnection.new(pipeClient, pipeServer);
  serverConnection.register("echo", echo)
  serverConnection.register("echoDemoObject", echoDemoObject)
  discard serverConnection.start();

  let clientConnection = StreamConnection.new(pipeServer, pipeClient);
  discard clientConnection.start();

  test "Simple call.":
    let response = clientConnection.call("echo", %"input").waitFor().getStr
    doAssert (response == "input")
    doAssert (cachedInput.getStr == "input")

  test "Call with object":
    let input =  DemoObject(foo: 1);
    let response = clientConnection.call("echoDemoObject", %input).waitFor()
    assert(to(response, DemoObject) == input)

  pipeClient.close()
  pipeServer.close()
