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
