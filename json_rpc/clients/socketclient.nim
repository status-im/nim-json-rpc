# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/tables,
  chronicles,
  results,
  chronos,
  ../client,
  ../errors,
  ../private/jrpc_sys

export client, errors

logScope:
  topics = "JSONRPC-SOCKET-CLIENT"

type
  RpcSocketClient* = ref object of RpcClient
    transport*: StreamTransport
    address*: TransportAddress
    loop*: Future[void]

const defaultMaxRequestLength* = 1024 * 128

{.push gcsafe, raises: [].}

proc new*(T: type RpcSocketClient): T =
  T()

proc newRpcSocketClient*: RpcSocketClient =
  ## Creates a new client instance.
  RpcSocketClient.new()

method call*(client: RpcSocketClient, name: string,
             params: RequestParamsTx): Future[JsonString] {.async, gcsafe.} =
  ## Remotely calls the specified RPC method.
  let id = client.getNextId()
  var jsonBytes = requestTxEncode(name, params, id) & "\r\n"
  if client.transport.isNil:
    raise newException(JsonRpcError,
                    "Transport is not initialised (missing a call to connect?)")

  # completed by processMessage.
  var newFut = newFuture[JsonString]()
  # add to awaiting responses
  client.awaiting[id] = newFut

  let res = await client.transport.write(jsonBytes)
  # TODO: Add actions when not full packet was send, e.g. disconnect peer.
  doAssert(res == jsonBytes.len)

  return await newFut

method callBatch*(client: RpcSocketClient,
                  calls: RequestBatchTx): Future[ResponseBatchRx]
                    {.gcsafe, async.} =
  if client.transport.isNil:
    raise newException(JsonRpcError,
      "Transport is not initialised (missing a call to connect?)")

  if client.batchFut.isNil or client.batchFut.finished():
    client.batchFut = newFuture[ResponseBatchRx]()

  let
    jsonBytes = requestBatchEncode(calls) & "\r\n"
    res = await client.transport.write(jsonBytes)

  # TODO: Add actions when not full packet was send, e.g. disconnect peer.
  doAssert(res == jsonBytes.len)

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
          error "Error when processing RPC message", msg=res.error
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
      error "Error when reconnecting to server", msg=exc.msg
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
