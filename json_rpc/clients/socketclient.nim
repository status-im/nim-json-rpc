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

export client

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

proc processData(client: RpcSocketClient) {.async.} =
  while true:
    while true:
      var value = await client.transport.readLine(defaultMaxRequestLength)
      if value == "":
        # transmission ends
        await client.transport.closeWait()
        break

      let res = client.processMessage(value)
      if res.isErr:
        error "error when processing message", msg=res.error
        raise newException(JsonRpcError, res.error)

    # async loop reconnection and waiting
    client.transport = await connect(client.address)

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
