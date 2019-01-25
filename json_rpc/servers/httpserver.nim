import json, strutils
import chronicles, httputils, asyncdispatch2
import ../server

logScope:
  topic = "JSONRPC-HTTP-SERVER"

const
  MaxHttpHeadersSize = 8192       # maximum size of HTTP headers in octets
  MaxHttpRequestSize = 128 * 1024 # maximum size of HTTP body in octets
  HttpHeadersTimeout = 120000     # timeout for receiving headers (120 sec)
  HttpBodyTimeout = 12000         # timeout for receiving body (12 sec)
  HeadersMark = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

type
  ReqStatus = enum
    Success, Error, ErrorFailure

  RpcHttpServer* = ref object of RpcServer
    servers: seq[StreamServer]

proc sendAnswer(transp: StreamTransport, version: HttpVersion, code: HttpCode,
                data: string = ""): Future[bool] {.async.} =
  var answer = $version
  answer.add(" ")
  answer.add($code)
  answer.add("\r\n")
  answer.add("Date: " & httpDate() & "\r\n")
  if len(data) > 0:
    answer.add("Content-Type: application/json\r\n")
  answer.add("Content-Length: " & $len(data) & "\r\n")
  answer.add("\r\n")
  if len(data) > 0:
    answer.add(data)
  try:
    let res = await transp.write(answer)
    if res != len(answer):
      result = false
    result = true
  except:
    result = false

proc validateRequest(transp: StreamTransport,
                     header: HttpRequestHeader): Future[ReqStatus] {.async.} =
  if header.meth in {MethodPut, MethodDelete}:
    # Request method is either PUT or DELETE.
    debug "PUT/DELETE methods are not allowed", address = transp.remoteAddress()
    if await transp.sendAnswer(header.version, Http405):
      result = Error
    else:
      result = ErrorFailure
    return

  let length = header.contentLength()
  if length <= 0:
    # request length could not be calculated.
    debug "Content-Length is missing or 0", address = transp.remoteAddress()
    if await transp.sendAnswer(header.version, Http411):
      result = Error
    else:
      result = ErrorFailure
    return

  if length > MaxHttpRequestSize:
    # request length is more then `MaxHttpRequestSize`.
    debug "Maximum size of request body reached",
          address = transp.remoteAddress()
    if await transp.sendAnswer(header.version, Http413):
      result = Error
    else:
      result = ErrorFailure
    return

  var ctype = header["Content-Type"]
  # might be "application/json; charset=utf-8"
  if "application/json" notin ctype.toLowerAscii():
    # Content-Type header is not "application/json"
    debug "Content type must be application/json",
          address = transp.remoteAddress()
    if await transp.sendAnswer(header.version, Http415):
      result = Error
    else:
      result = ErrorFailure
    return

  result = Success

proc processClient(server: StreamServer,
                   transp: StreamTransport) {.async, gcsafe.} =
  ## Process transport data to the RPC server
  var rpc = getUserData[RpcHttpServer](server)
  var buffer = newSeq[byte](MaxHttpHeadersSize)
  var header: HttpRequestHeader
  var connection: string

  info "Received connection", address = transp.remoteAddress()
  while true:
    try:
      let hlenfut = transp.readUntil(addr buffer[0], MaxHttpHeadersSize,
                                     HeadersMark)
      let ores = await withTimeout(hlenfut, HttpHeadersTimeout)
      if not ores:
        # Timeout
        debug "Timeout expired while receiving headers",
              address = transp.remoteAddress()
        let res = await transp.sendAnswer(HttpVersion11, Http408)
        transp.close()
        break
      else:
        let hlen = hlenfut.read()
        buffer.setLen(hlen)
        header = buffer.parseRequest()
        if header.failed():
          # Header could not be parsed
          debug "Malformed header received",
                address = transp.remoteAddress()
          let res = await transp.sendAnswer(HttpVersion11, Http400)
          transp.close()
          break
    except TransportLimitError:
      # size of headers exceeds `MaxHttpHeadersSize`
      debug "Maximum size of headers limit reached",
            address = transp.remoteAddress()
      let res = await transp.sendAnswer(HttpVersion11, Http413)
      transp.close()
      break
    except TransportIncompleteError:
      # remote peer disconnected
      debug "Remote peer disconnected", address = transp.remoteAddress()
      transp.close()
      break
    except TransportOsError:
      debug "Problems with networking", address = transp.remoteAddress(),
            error = getCurrentExceptionMsg()
      transp.close()
      break

    let vres = await validateRequest(transp, header)

    if vres == Success:
      info "Received valid RPC request", address = transp.remoteAddress()

      # we need to get `Connection` header value before, because
      # we are reusing `buffer`, and its value will be lost.
      connection = header["Connection"]

      let length = header.contentLength()
      buffer.setLen(length)
      try:
        let blenfut = transp.readExactly(addr buffer[0], length)
        let ores = await withTimeout(blenfut, HttpBodyTimeout)
        if not ores:
          # Timeout
          debug "Timeout expired while receiving request body",
                address = transp.remoteAddress()
          let res = await transp.sendAnswer(header.version, Http413)
          transp.close()
          break
        else:
          blenfut.read()
      except TransportIncompleteError:
        # remote peer disconnected
        debug "Remote peer disconnected", address = transp.remoteAddress()
        transp.close()
        break
      except TransportOsError:
        debug "Problems with networking", address = transp.remoteAddress(),
              error = getCurrentExceptionMsg()
        transp.close()
        break

      let future = rpc.route(cast[string](buffer))
      yield future
      if future.failed:
        # rpc.route exception
        debug "Internal error, while processing RPC call",
              address = transp.remoteAddress()
        let res = await transp.sendAnswer(header.version, Http503)
        if not res:
          transp.close()
          break
      else:
        var data = future.read()
        let res = await transp.sendAnswer(header.version, Http200, data)
        info "RPC result has been sent", address = transp.remoteAddress()
        if not res:
          transp.close()
          break
    elif vres == ErrorFailure:
      debug "Remote peer disconnected", address = transp.remoteAddress()
      transp.close()
      break

    if header.version in {HttpVersion09, HttpVersion10}:
      debug "Disconnecting client", address = transp.remoteAddress()
      transp.close()
      break
    else:
      if connection == "close":
        debug "Disconnecting client", address = transp.remoteAddress()
        transp.close()
        break

# Utility functions for setting up servers using stream transport addresses

proc addStreamServer*(server: RpcHttpServer, address: TransportAddress) =
  try:
    info "Creating server on ", address = $address
    var transServer = createStreamServer(address, processClient,
                                         {ReuseAddr}, udata = server)
    server.servers.add(transServer)
  except:
    error "Failed to create server", address = $address,
                                     message = getCurrentExceptionMsg()

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError, "Unable to create server!")

proc addStreamServers*(server: RpcHttpServer,
                       addresses: openarray[TransportAddress]) =
  for item in addresses:
    server.addStreamServer(item)

proc addStreamServer*(server: RpcHttpServer, address: string) =
  ## Create new server and assign it to addresses ``addresses``.
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    added = 0

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, IpAddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, IpAddressFamily.IPv6)
  except:
    discard

  for r in tas4:
    server.addStreamServer(r)
    added.inc
  for r in tas6:
    server.addStreamServer(r)
    added.inc

  if added == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to get address!")

proc addStreamServers*(server: RpcHttpServer, addresses: openarray[string]) =
  for address in addresses:
    server.addStreamServer(address)

proc addStreamServer*(server: RpcHttpServer, address: string, port: Port) =
  var
    tas4: seq[TransportAddress]
    tas6: seq[TransportAddress]
    added = 0

  # Attempt to resolve `address` for IPv4 address space.
  try:
    tas4 = resolveTAddress(address, port, IpAddressFamily.IPv4)
  except:
    discard

  # Attempt to resolve `address` for IPv6 address space.
  try:
    tas6 = resolveTAddress(address, port, IpAddressFamily.IPv6)
  except:
    discard

  if len(tas4) == 0 and len(tas6) == 0:
    # Address was not resolved, critical error.
    raise newException(RpcAddressUnresolvableError,
                       "Address " & address & " could not be resolved!")

  for r in tas4:
    server.addStreamServer(r)
    added.inc
  for r in tas6:
    server.addStreamServer(r)
    added.inc

  if len(server.servers) == 0:
    # Server was not bound, critical error.
    raise newException(RpcBindError,
                      "Could not setup server on " & address & ":" & $int(port))

proc newRpcHttpServer*(): RpcHttpServer =
  RpcHttpServer(router: newRpcRouter(), servers: @[])

proc newRpcHttpServer*(addresses: openarray[TransportAddress]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer()
  result.addStreamServers(addresses)

proc newRpcHttpServer*(addresses: openarray[string]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcHttpServer()
  result.addStreamServers(addresses)

proc start*(server: RpcHttpServer) =
  ## Start the RPC server.
  for item in server.servers:
    debug "HTTP RPC server started", address = item.local
    item.start()

proc stop*(server: RpcHttpServer) =
  ## Stop the RPC server.
  for item in server.servers:
    debug "HTTP RPC server stopped", address = item.local
    item.stop()

proc close*(server: RpcHttpServer) =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    item.close()

proc closeWait*(server: RpcHttpServer) {.async.} =
  ## Cleanup resources of RPC server.
  for item in server.servers:
    await item.closeWait()
