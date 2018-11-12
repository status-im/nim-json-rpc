import json, strutils, tables
import chronicles, httputils, asyncdispatch2
import ../client

logScope:
  topic = "JSONRPC-HTTP-CLIENT"

type
  HttpClientOptions* = object
    httpMethod: HttpMethod

  RpcHttpClient* = ref object of RpcClient
    transp*: StreamTransport
    addresses: seq[TransportAddress]
    options: HttpClientOptions

const
  MaxHttpHeadersSize = 8192       # maximum size of HTTP headers in octets
  MaxHttpRequestSize = 128 * 1024 # maximum size of HTTP body in octets
  HttpHeadersTimeout = 120000     # timeout for receiving headers (120 sec)
  HttpBodyTimeout = 12000         # timeout for receiving body (12 sec)
  HeadersMark = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

proc sendRequest(transp: StreamTransport,
                 data: string, options: HttpClientOptions): Future[bool] {.async.} =
  var request = $options.httpMethod & " / "
  request.add($HttpVersion11)
  request.add("\r\n")
  request.add("Date: " & httpDate() & "\r\n")
  request.add("Host: " & $transp.remoteAddress & "\r\n")
  request.add("Content-Type: application/json\r\n")
  request.add("Content-Length: " & $len(data) & "\r\n")
  request.add("Connection: keep-alive\r\n")
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
  if ctype.toLowerAscii() != "application/json":
    # Content-Type header is not "application/json"
    debug "Content type must be application/json",
          address = transp.remoteAddress()
    result = false
    return

  let length = header.contentLength()
  if length <= 0:
    # request length could not be calculated.
    debug "Content-Length is missing or 0", address = transp.remoteAddress()
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
    transp.close()
    result = ""
    return

  let length = header.contentLength()
  buffer.setLen(length)
  try:
    let blenfut = transp.readExactly(addr buffer[0], length)
    let ores = await withTimeout(blenfut, HttpBodyTimeout)
    if not ores:
      # Timeout
      debug "Timeout expired while receiving request body",
            address = transp.remoteAddress()
      error = true
    else:
      blenfut.read()

  except TransportIncompleteError:
    # remote peer disconnected
    debug "Remote peer disconnected", address = transp.remoteAddress()
    error = true
  except TransportOsError:
    debug "Problems with networking", address = transp.remoteAddress(),
          error = getCurrentExceptionMsg()
    error = true

  if error:
    transp.close()
    result = ""
  else:
    result = cast[string](buffer)

proc init(opts: var HttpClientOptions) =
  opts.httpMethod = MethodGet

proc newRpcHttpClient*(): RpcHttpClient =
  ## Creates a new HTTP client instance.
  new result
  result.initRpcClient()
  result.options.init()

proc httpMethod*(client: RpcHttpClient): HttpMethod =
  client.options.httpMethod

proc httpMethod*(client: RpcHttpClient, m: HttpMethod) =
  client.options.httpMethod = m

proc call*(client: RpcHttpClient, name: string,
           params: JsonNode): Future[Response] {.async.} =
  ## Remotely calls the specified RPC method.
  let id = client.getNextId()

  var value = $rpcCallNode(name, params, id) & "\c\l"
  if isNil(client.transp) or client.transp.closed():
    raise newException(ValueError,
      "Transport is not initialised or already closed")
  let res = await client.transp.sendRequest(value, client.options)
  if not res:
    debug "Failed to send message to RPC server",
          address = client.transp.remoteAddress(), msg_len = res
    client.transp.close()
    raise newException(ValueError, "Transport error")
  else:
    debug "Message sent to RPC server", address = client.transp.remoteAddress(),
          msg_len = res

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  client.awaiting[id] = newFut
  result = await newFut

proc processData(client: RpcHttpClient) {.async.} =
  while true:
    var value = await client.transp.recvData()
    if value == "":
      break
    debug "Received response from RPC server",
          address = client.transp.remoteAddress(),
          msg_len = len(value)
    client.processMessage(value)

  # async loop reconnection and waiting
  client.transp = await connect(client.addresses[0])

proc connect*(client: RpcHttpClient, address: string, port: Port) {.async.} =
  client.addresses = resolveTAddress(address, port)
  client.transp = await connect(client.addresses[0])
  asyncCheck processData(client)
