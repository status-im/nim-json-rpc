import
  std/json,
  unittest,
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  ../json_rpc/streamconnection

type
  DemoObject* = object
    foo*: int
    bar*: int

# for testing purposes
var
  cachedInput: string
  cachedDemoObject = newFuture[DemoObject]()
  futureId = newFuture[int]()

proc echo(params: string): Future[string] {.async,
    raises: [CatchableError, Exception].} =
  {.gcsafe.}:
    cachedInput = params;
  return params

proc notifyDemoObject(params: DemoObject): Future[void] {.async} =
  {.gcsafe.}:
    cachedDemoObject.complete(params);
  return

suite "Client/server over JSONRPC":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  proc echoDemoObject(params: DemoObject): Future[DemoObject] {.async,
      raises: [CatchableError, Exception].} =
    return params

  proc echoDemoObjectWithId(params: DemoObject, id: int): Future[DemoObject] {.async,
      raises: [CatchableError, Exception].} =
    {.gcsafe.}:
      futureId.complete(id)
    return params

  proc echoDemoObjectRaiseError(params: DemoObject): Future[DemoObject] {.async,
      raises: [CatchableError, Exception].} =
    raise newException(ValueError, "ValueError")

  let serverConnection = StreamConnection.new(pipeServer);
  serverConnection.register("echo", echo)
  serverConnection.register("echoDemoObject", echoDemoObject)
  serverConnection.register("echoDemoObjectWithId", echoDemoObjectWithId)
  serverConnection.register("echoDemoObjectRaise", echoDemoObjectRaiseError)
  serverConnection.registerNotification("demoObjectNotification", notifyDemoObject)

  discard serverConnection.start(asyncPipeInput(pipeClient));

  let clientConnection = StreamConnection.new(pipeClient);
  discard clientConnection.start(asyncPipeInput(pipeServer));

  test "Simple call.":
    let response = clientConnection.call("echo", %"input").waitFor()
    doAssert (response.getStr == "input")
    doAssert (cachedInput == "input")

  test "Call with object.":
    let input =  DemoObject(foo: 1);
    let response = clientConnection.call("echoDemoObject", %input).waitFor()
    assert(to(response, DemoObject) == input)

  test "Sending notification.":
    let input =  DemoObject(foo: 2);
    clientConnection.notify("demoObjectNotification", %input).waitFor()
    assert(cachedDemoObject.waitFor == input)

  test "Call with object/exception":
    let input =  DemoObject(foo: 1);
    try:
      discard clientConnection.call("echoDemoObjectRaise", %input).waitFor()
      doAssert false
    except ValueError as e:
      discard # expected

  test "Call with object.":
    let input =  DemoObject(foo: 1);
    let response = clientConnection.call("echoDemoObjectWithId", %input).waitFor()
    assert(to(response, DemoObject) == input)
    assert(futureId.read == 4)

  pipeClient.close()
  pipeServer.close()
