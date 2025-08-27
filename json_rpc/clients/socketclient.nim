# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/tables,
  chronicles,
  results,
  chronos,
  json_serialization/std/net as jsnet,
  ../client,
  ../errors,
  ../private/jrpc_sys

export client, errors, jsnet

logScope:
  topics = "JSONRPC-SOCKET-CLIENT"

type
  RpcSocketClient* = ref object of RpcClient
    transport*: StreamTransport
    address*: TransportAddress
    loop*: Future[void]

const defaultMaxRequestLength* = 1024 * 128

proc new*(T: type RpcSocketClient): T =
  T()

proc newRpcSocketClient*: RpcSocketClient =
  ## Creates a new client instance.
  RpcSocketClient.new()

method call*(client: RpcSocketClient, name: string,
             params: RequestParamsTx): Future[JsonString] {.async.} =
  ## Remotely calls the specified RPC method.
  if client.transport.isNil:
    raise newException(JsonRpcError,
                    "Transport is not initialised (missing a call to connect?)")

  let
    id = client.getNextId()
    reqBody = requestTxEncode(name, params, id) & "\r\n"
    newFut = newFuture[JsonString]()  # completed by processMessage

  # add to awaiting responses
  client.awaiting[id] = newFut

  debug "Sending JSON-RPC request",
         address = $client.address, len = len(reqBody), name, id

  let res = await client.transport.write(reqBody)
  # TODO: Add actions when not full packet was send, e.g. disconnect peer.
  doAssert(res == reqBody.len)

  return await newFut

method callBatch*(client: RpcSocketClient,
                  calls: RequestBatchTx): Future[ResponseBatchRx]
                    {.async.} =
  if client.transport.isNil:
    raise newException(JsonRpcError,
      "Transport is not initialised (missing a call to connect?)")

  if client.batchFut.isNil or client.batchFut.finished():
    client.batchFut = newFuture[ResponseBatchRx]()

  let reqBody = requestBatchEncode(calls) & "\r\n"
  debug "Sending JSON-RPC batch",
        address = $client.address, len = len(reqBody)
  let res = await client.transport.write(reqBody)

  # TODO: Add actions when not full packet was send, e.g. disconnect peer.
  doAssert(res == reqBody.len)

  return await client.batchFut

proc processData(client: RpcSocketClient) {.async: (raises: []).} =
  while true:
    var localException: ref JsonRpcError
    while true:
      try:
        var value = await client.transport.readLine(defaultMaxRequestLength)
        if value == "":
          # transmission ends
          await client.transport.closeWait()
          break

        let res = client.processMessage(value)
        if res.isErr:
          localException = newException(JsonRpcError, res.error)
          break
      except TransportError as exc:
        localException = newException(JsonRpcError, exc.msg)
        await client.transport.closeWait()
        break
      except CancelledError as exc:
        localException = newException(JsonRpcError, exc.msg)
        await client.transport.closeWait()
        break

    if localException.isNil.not:
      for _,fut in client.awaiting:
        fut.fail(localException)
      if client.batchFut.isNil.not and not client.batchFut.completed():
        client.batchFut.fail(localException)

    # async loop reconnection and waiting
    try:
      info "Reconnect to server", address=`$`(client.address)
      client.transport = await connect(client.address)
    except TransportError as exc:
      error "Error when reconnecting to server", msg=exc.msg
      break
    except CancelledError as exc:
      debug "Server connection was cancelled", msg=exc.msg
      break

proc connect*(client: RpcSocketClient, address: string, port: Port) {.async.} =
  let addresses = resolveTAddress(address, port)
  client.transport = await connect(addresses[0])
  client.address = addresses[0]
  client.loop = processData(client)

proc connect*(client: RpcSocketClient, address: TransportAddress) {.async.} =
  client.transport = await connect(address)
  client.address = address
  client.loop = processData(client)

method close*(client: RpcSocketClient) {.async.} =
  await client.loop.cancelAndWait()
  if not client.transport.isNil:
    client.transport.close()
    client.transport = nil
