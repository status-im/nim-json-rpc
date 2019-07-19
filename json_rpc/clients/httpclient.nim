import json, strutils, tables
import chronicles, httputils, chronos, json_serialization/std/net
import ../client

logScope:
  topics = "JSONRPC-HTTP-CLIENT"

type
  HttpClientOptions* = object
    httpMethod: HttpMethod

  RpcHttpClient* = ref object of RpcClient
    loop: Future[void]
    addresses: seq[TransportAddress]
    options: HttpClientOptions

const
  MaxHttpHeadersSize = 8192        # maximum size of HTTP headers in octets
  MaxHttpRequestSize = 128 * 1024  # maximum size of HTTP body in octets
  HttpHeadersTimeout = 120.seconds # timeout for receiving headers (120 sec)
  HttpBodyTimeout = 12.seconds     # timeout for receiving body (12 sec)
  HeadersMark = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

proc sendRequest(transp: StreamTransport,
                 data: string, httpMethod: HttpMethod): Future[bool] {.async.} =
  var request = $httpMethod & " / "
  request.add($HttpVersion10)
  request.add("\r\n")
  request.add("Date: " & httpDate() & "\r\n")
  request.add("Host: " & $transp.remoteAddress & "\r\n")
  request.add("Content-Type: application/json\r\n")
  request.add("Content-Length: " & $len(data) & "\r\n")
  request.add("\r\n")
  if len(data) > 0:
    request.add(data)
  try:
    let res = await transp.write(cast[seq[char]](request))
    if res != len(request):
      result = false
    result = true
  except:
    result = false

proc validateResponse*(transp: StreamTransport,
                       header: HttpResponseHeader): bool =
  if header.code != 200:
    debug "Server returns error",
           httpcode = header.code,
           httpreason = header.reason(),
           address = transp.remoteAddress()
    result = false
    return

  var ctype = header["Content-Type"]
  # might be "application/json; charset=utf-8"
  if "application/json" notin ctype.toLowerAscii():
    # Content-Type header is not "application/json"
    debug "Content type must be application/json",
          address = transp.remoteAddress()
    result = false
    return

  let length = header.contentLength()
  if length <= 0:
    if header.version == HttpVersion11:
      if header["Connection"].toLowerAscii() != "close":
        # Response body length could not be calculated.
        if header["Transfer-Encoding"].toLowerAscii() == "chunked":
          debug "Chunked encoding is not supported",
                address = transp.remoteAddress()
        else:
          debug "Content body size could not be calculated",
                address = transp.remoteAddress()
        result = false
        return

  result = true

proc recvData(transp: StreamTransport): Future[string] {.async.} =
  var buffer = newSeq[byte](MaxHttpHeadersSize)
  var header: HttpResponseHeader
  var error = false
  try:
    let hlenfut = transp.readUntil(addr buffer[0], MaxHttpHeadersSize,
                                   HeadersMark)
    let ores = await withTimeout(hlenfut, HttpHeadersTimeout)
    if not ores:
      # Timeout
      debug "Timeout expired while receiving headers",
             address = transp.remoteAddress()
      error = true
    else:
      let hlen = hlenfut.read()
      buffer.setLen(hlen)
      header = buffer.parseResponse()
      if header.failed():
        # Header could not be parsed
        debug "Malformed header received",
              address = transp.remoteAddress()
        error = true
  except TransportLimitError:
    # size of headers exceeds `MaxHttpHeadersSize`
    debug "Maximum size of headers limit reached",
          address = transp.remoteAddress()
    error = true
  except TransportIncompleteError:
    # remote peer disconnected
    debug "Remote peer disconnected", address = transp.remoteAddress()
    error = true
  except TransportOsError:
    debug "Problems with networking", address = transp.remoteAddress(),
          error = getCurrentExceptionMsg()
    error = true

  if error or not transp.validateResponse(header):
    result = ""
    return

  let length = header.contentLength()
  try:
    if length > 0:
      # `Content-Length` is present in response header.
      buffer.setLen(length)
      let blenfut = transp.readExactly(addr buffer[0], length)
      let ores = await withTimeout(blenfut, HttpBodyTimeout)
      if not ores:
        # Timeout
        debug "Timeout expired while receiving request body",
              address = transp.remoteAddress()
        error = true
      else:
        blenfut.read()
    else:
      # `Content-Length` is not present in response header, so we are reading
      # everything until connection will be closed.
      var blenfut = transp.read()
      let ores = await withTimeout(blenfut, HttpBodyTimeout)
      if not ores:
        # Timeout
        debug "Timeout expired while receiving request body",
              address = transp.remoteAddress()
        error = true
      else:
        buffer = blenfut.read()
  except TransportIncompleteError:
    # remote peer disconnected
    debug "Remote peer disconnected", address = transp.remoteAddress()
    error = true
  except TransportOsError:
    debug "Problems with networking", address = transp.remoteAddress(),
          error = getCurrentExceptionMsg()
    error = true

  if error:
    result = ""
  else:
    result = cast[string](buffer)

proc init(opts: var HttpClientOptions) =
  opts.httpMethod = MethodPost

proc newRpcHttpClient*(): RpcHttpClient =
  ## Creates a new HTTP client instance.
  new result
  result.initRpcClient()
  result.options.init()

proc httpMethod*(client: RpcHttpClient): HttpMethod =
  client.options.httpMethod

proc httpMethod*(client: RpcHttpClient, m: HttpMethod) =
  client.options.httpMethod = m

method call*(client: RpcHttpClient, name: string,
           params: JsonNode): Future[Response] {.async, gcsafe.} =
  ## Remotely calls the specified RPC method.
  let id = client.getNextId()

  let transp = await connect(client.addresses[0])
  var reqBody = $rpcCallNode(name, params, id)
  echo "Sending (", client.httpMethod, "): ", reqBody
  let res = await transp.sendRequest(reqBody, client.httpMethod)
  if not res:
    debug "Failed to send message to RPC server",
          address = transp.remoteAddress(), msg_len = len(reqBody)
    await transp.closeWait()
    raise newException(ValueError, "Transport error")
  else:
    debug "Message sent to RPC server", address = transp.remoteAddress(),
          msg_len = len(reqBody)
    trace "Message", msg = reqBody

  var value = await transp.recvData()
  await transp.closeWait()
  if value.len == 0:
    raise newException(ValueError, "Empty response from server")

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  client.awaiting[id] = newFut
  client.processMessage(value)
  result = await newFut

proc connect*(client: RpcHttpClient, address: string, port: Port) {.async.} =
  client.addresses = resolveTAddress(address, port)
