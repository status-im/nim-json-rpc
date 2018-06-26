import rpcserver, rpcclient, tables, chronicles, strformat, strutils
export rpcserver, rpcclient

proc extractJsonStr(msgSource: string, value: string): string =
  result = ""
  let p1 = find(value, '{')
  if p1 > -1:
    let p2 = rFind(value, '}')
    if p2 == -1:
      info "Cannot find json end brace", source = msgSource, msg = value
    else:
      result = value[p1 .. p2]
      debug "Extracted json", source = msgSource, json = result
  else:
    info "Cannot find json start brace", source = msgSource, msg = value

type
  RpcHttpServer* = RpcServer[StreamServer]

defineRpcServerTransport(httpProcessClient):
  write:
    const contentType = "Content-Type: application/json-rpc"
    let msg = &"Host: {$transport.localAddress} {contentType} Content-Length: {$value.len} {value}"
    debug "HTTP server: write", msg = msg
    transport.write(msg)
  afterRead:
    debug "HTTP server: read", msg = value
    value = "HTTP Server".extractJsonStr(value)

proc newRpcHttpServer*(addresses: openarray[TransportAddress]): RpcHttpServer = 
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcServer[StreamServer]()
  result.addStreamServers(addresses, httpProcessClient)

proc newRpcHttpServer*(addresses: openarray[string]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.  
  result = newRpcServer[StreamServer]()
  result.addStreamServers(addresses, httpProcessClient)

proc newRpcHttpServer*(address = "localhost", port: Port = Port(8545)): RpcHttpServer =
  result = newRpcServer[StreamServer]()
  result.addStreamServer(address, port, httpProcessClient)

type RpcHttpClient* = RpcClient[StreamTransport, TransportAddress]

defineRpcClientTransport(StreamTransport, TransportAddress, "http"):
  write:
    const contentType = "Content-Type: application/json-rpc"
    value = &"Host: {$client.transp.localAddress} {contentType} Content-Length: {$value.len} {value}"
    debug "HTTP client: write", msg = value
    client.transp.write(value)
  afterRead:
    # Strip out http header
    # TODO: Performance
    debug "HTTP client: read", msg = value
    value = "HTTP Client".extractJsonStr(value)

proc newRpcHttpClient*(): RpcHttpClient =
  result = newRpcClient[StreamTransport, TransportAddress]()

