import json, strutils, tables
import chronicles, httputils, asyncdispatch2
import ../client

logScope:
  topic = "JSONRPC-HTTP-CLIENT"

type
  HttpClientOptions* = object
    httpMethod: HttpMethod
    httpVersion: HttpVersion

  RpcHttpClient* = ref object of RpcClient
    transp*: StreamTransport
    addresses: seq[TransportAddress]
    options: HttpClientOptions

const
  MaxHttpHeadersSize = 8192       # maximum size of HTTP headers in octets
  MaxHttpRequestSize = 128 * 1024 # maximum size of HTTP body in octets
  HttpBlockLength    = 4 * 1024   # size of block when reading HTTP body in octets
  HttpHeadersTimeout = 120000     # timeout for receiving headers (120 sec)
  HttpBodyTimeout = 12000         # timeout for receiving body (12 sec)
  HeadersMark = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

proc sendRequest(transp: StreamTransport,
                 data: string, httpMethod: HttpMethod,
                 httpVersion: HttpVersion): Future[bool] {.async.} =
  var request = $httpMethod & " / "
  request.add($httpVersion)
  request.add("\r\n")
  request.add("Date: " & httpDate() & "\r\n")
  request.add("Content-Type: application/json\r\n")
  request.add("Content-Length: " & $len(data) & "\r\n")

  if httpVersion == HttpVersion11:
    request.add("Host: " & $transp.remoteAddress & "\r\n")
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
  if length < 0:
    # request length could not be calculated.
    debug "invalid Content-Length", address = transp.remoteAddress()
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

  try:
    var length = header.contentLength()
    # HTTP/1.0 can have `Content-Length` optionally
    let readLength = if length == 0: HttpBlockLength
                     else: length
    # read the body until eof
    var currLen = 0
    while not transp.atEof():
      if currLen + readLength > buffer.len:
        buffer.setLen(currLen + readLength)

      let bytesReadFut = transp.readOnce(addr buffer[currLen], readLength)
      let ores = await withTimeout(bytesReadFut, HttpBodyTimeout)
      if not ores:
        # Timeout
        debug "Timeout expired while receiving request body",
              address = transp.remoteAddress()
        error = true
        break
      else:
        var bytesRead = bytesReadFut.read()
        inc(currLen, bytesRead)

    if not error:
      buffer.setLen(currLen)
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

proc init(opts: var HttpClientOptions, httpVersion: HttpVersion) =
  opts.httpMethod = MethodGet
  opts.httpVersion = httpVersion

proc newRpcHttpClient*(httpVersion = HttpVersion10): RpcHttpClient =
  ## Creates a new HTTP client instance.
  new result
  result.initRpcClient()
  # currently it only support HTTP version 1.0
  # but it we can expand it later
  var httpVersion = httpVersion
  if httpVersion notin {HttpVersion10}:
    debug "unsupported HTTP version", version=httpVersion
    httpVersion = HttpVersion10 # fallback to HTTP/1.0
  result.options.init(httpVersion)

proc httpMethod*(client: RpcHttpClient): HttpMethod =
  client.options.httpMethod

proc httpMethod*(client: RpcHttpClient, m: HttpMethod) =
  client.options.httpMethod = m

proc processData(client: RpcHttpClient) {.async.} =
  var value = await client.transp.recvData()
  if value == "": return
  debug "Received response from RPC server",
        address = client.transp.remoteAddress(),
        msg_len = len(value)
  client.processMessage(value)

proc call*(client: RpcHttpClient, name: string,
           params: JsonNode, httpMethod: HttpMethod): Future[Response] {.async.} =

  if client.options.httpVersion == HttpVersion10:
    client.transp = await connect(client.addresses[0])
    asyncCheck processData(client)
  else:
    if client.transp.closed():
      client.transp = await connect(client.addresses[0])
      asyncCheck processData(client)

  ## Remotely calls the specified RPC method.
  let id = client.getNextId()

  var value = $rpcCallNode(name, params, id) & "\c\l"
  if isNil(client.transp) or client.transp.closed():
    raise newException(ValueError,
      "Transport is not initialised or already closed")
  let res = await client.transp.sendRequest(value, httpMethod,
    client.options.httpVersion)
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

  if client.options.httpVersion == HttpVersion10:
    if not client.transp.closed(): client.transp.close()

template call*(client: RpcHttpClient, name: string,
               params: JsonNode): untyped =
  client.call(name, params, client.httpMethod)

proc connect*(client: RpcHttpClient, address: string, port: Port) {.async.} =
  client.addresses = resolveTAddress(address, port)

  if client.options.httpVersion != HttpVersion10:
    client.transp = await connect(client.addresses[0])
    asyncCheck processData(client)
