import rpcserver, tables, chronicles
export rpcserver

type
  ClientHttpWrapper* = StreamTransport
  RpcHttpServer* = RpcServer[StreamServer]

proc httpHeader(host: string, length: int): string =
  "Host: " & host & "Content-Type: application/json-rpc Content-Length: " & $length

proc write(client: ClientHttpWrapper, data: var string): Future[int] =
  # TODO: WIP
  let d = httpHeader($client.localAddress, data.len) & data
  result = client.write(d)

proc readLine(client: ClientHttpWrapper, bytesToRead: int): Future[string] {.async.} =
  result = await client.readLine
  # TODO: Strip http

proc processHtmlClient*(server: StreamServer, client: ClientHttpWrapper) {.async, gcsafe.} =
  await server.processClient(client)

proc newRpcHttpServer*(addresses: openarray[TransportAddress]): RpcHttpServer = 
  ## Create new server and assign it to addresses ``addresses``.
  result = newRpcServer[StreamServer]().RpcHttpServer
  result.addStreamServers(addresses, processHtmlClient)

proc newRpcHttpServer*(addresses: openarray[string]): RpcHttpServer =
  ## Create new server and assign it to addresses ``addresses``.  
  result = newRpcServer[StreamServer]().RpcHttpServer
  result.addStreamServers(addresses, processHtmlClient)

proc newRpcHttpServer*(address = "localhost", port: Port = Port(8545)): RpcHttpServer =
  result = newRpcServer[StreamServer]().RpcHttpServer
  result.addStreamServer(address, port, processHtmlClient)

