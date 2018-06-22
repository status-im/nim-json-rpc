import rpcserver, tables, chronicles, strformat
export rpcserver

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

