import
  std/[strutils, tables, uri],
  stew/[byteutils, results],
  chronos/apps/http/httpclient as chronosHttpClient,
  chronicles, httputils, json_serialization/std/net,
  ".."/[client, errors]

export
  client

{.push raises: [Defect].}

logScope:
  topics = "JSONRPC-HTTP-CLIENT"

type
  HttpClientOptions* = object
    httpMethod: HttpMethod

  RpcHttpClient* = ref object of RpcClient
    httpSession: HttpSessionRef
    httpAddress: HttpResult[HttpAddress]
    maxBodySize: int
    getHeaders: GetJsonRpcRequestHeaders

const
  MaxHttpRequestSize = 128 * 1024 * 1024 # maximum size of HTTP body in octets

proc new(
    T: type RpcHttpClient, maxBodySize = MaxHttpRequestSize, secure = false,
    getHeaders: GetJsonRpcRequestHeaders = nil): T =
  let httpSessionFlags = if secure:
    {
      HttpClientFlag.NoVerifyHost,
      HttpClientFlag.NoVerifyServerName
    }
  else:
    {}

  T(
    maxBodySize: maxBodySize,
    httpSession: HttpSessionRef.new(flags = httpSessionFlags),
    getHeaders: getHeaders
  )

proc newRpcHttpClient*(
    maxBodySize = MaxHttpRequestSize, secure = false,
    getHeaders: GetJsonRpcRequestHeaders = nil): RpcHttpClient =
  RpcHttpClient.new(maxBodySize, secure, getHeaders)

method call*(client: RpcHttpClient, name: string,
             params: JsonNode): Future[Response]
            {.async, gcsafe.} =
  doAssert client.httpSession != nil
  if client.httpAddress.isErr:
    raise newException(RpcAddressUnresolvableError, client.httpAddress.error)

  var headers =
    if not isNil(client.getHeaders):
      client.getHeaders()
    else:
      @[]
  headers.add(("Content-Type", "application/json"))

  let
    id = client.getNextId()
    reqBody = $rpcCallNode(name, params, id)
    req = HttpClientRequestRef.post(client.httpSession,
                                    client.httpAddress.get,
                                    body = reqBody.toOpenArrayByte(0, reqBody.len - 1),
                                    headers = headers)
    res =
      try:
        await req.send()
      except CancelledError as e:
        raise e
      except CatchableError as e:
        raise (ref RpcPostError)(msg: "Failed to send POST Request with JSON-RPC.", parent: e)

  if res.status < 200 or res.status >= 300: # res.status is not 2xx (success)
    raise newException(ErrorResponse, "POST Response: " & $res.status)

  debug "Message sent to RPC server",
         address = client.httpAddress, msg_len = len(reqBody)
  trace "Message", msg = reqBody

  let resBytes =
    try:
      await res.getBodyBytes(client.maxBodySize)
    except CancelledError as e:
      raise e
    except CatchableError as exc:
      raise (ref FailedHttpResponse)(msg: "Failed to read POST Response for JSON-RPC.", parent: exc)

  let resText = string.fromBytes(resBytes)
  trace "Response", text = resText

  # completed by processMessage - the flow is quite weird here to accomodate
  # socket and ws clients, but could use a more thorough refactoring
  var newFut = newFuture[Response]()
  # add to awaiting responses
  client.awaiting[id] = newFut

  try:
    # Might raise for all kinds of reasons
    client.processMessage(resText)
  finally:
    # Need to clean up in case the answer was invalid
    client.awaiting.del(id)

  # processMessage should have completed this future - if it didn't, `read` will
  # raise, which is reasonable
  if newFut.finished:
    return newFut.read()
  else:
    # TODO: Provide more clarity regarding the failure here
    raise newException(InvalidResponse, "Invalid response")

proc connect*(client: RpcHttpClient, url: string) {.async.} =
  client.httpAddress = client.httpSession.getAddress(url)
  if client.httpAddress.isErr:
    raise newException(RpcAddressUnresolvableError, client.httpAddress.error)

proc connect*(client: RpcHttpClient, address: string, port: Port, secure: bool) {.async.} =
  var uri = Uri(
    scheme: if secure: "https" else: "http",
    hostname: address,
    port: $port)

  let res = getAddress(client.httpSession, uri)
  if res.isOk:
    client.httpAddress = res
  else:
    raise newException(RpcAddressUnresolvableError, res.error)

method close*(client: RpcHttpClient) {.async.} =
  if not client.httpSession.isNil:
    await client.httpSession.closeWait()
