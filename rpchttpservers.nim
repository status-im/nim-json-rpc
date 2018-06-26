import rpcserver, rpcclient, tables, chronicles, strformat, strutils
export rpcserver, rpcclient

type
  RpcHttpServer* = RpcServer[StreamServer]

defineRpcServerTransport(httpProcessClient):
  write:
    const contentType = "Content-Type: application/json-rpc"
    let msg = &"Host: {$client.localAddress} {contentType} Content-Length: {$value.len} {value}"
    debug "Http write", msg = msg
    client.write(msg)
  afterRead:
    # TODO: read: remove http to allow json validation
    debug "Http read", msg = value

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
  read:
    client.transp.readLine()
  afterRead:
    # Strip out http header
    # TODO: Performance
    let p1 = find(value, '{')
    if p1 > -1:
      let p2 = rFind(value, '}')
      if p2 == -1:
        info "Cannot find json end brace", msg = value
      else:
        value = value[p1 .. p2]
        debug "Extracted json", json = value
    else:
      info "Cannot find json start brace", msg = value

proc newRpcHttpClient*(): RpcHttpClient =
  result = newRpcClient[StreamTransport, TransportAddress]()

