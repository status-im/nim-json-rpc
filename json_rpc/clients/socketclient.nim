# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
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
  ../private/errors,
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

method call*(self: RpcSocketClient, name: string,
             params: RequestParamsTx): Future[StringOfJson] {.async, gcsafe.} =
  ## Remotely calls the specified RPC method.
  let id = self.getNextId()
  var value = requestTxEncode(name, params, id) & "\r\n"
  if self.transport.isNil:
    raise newException(JsonRpcError,
                    "Transport is not initialised (missing a call to connect?)")

  # completed by processMessage.
  var newFut = newFuture[StringOfJson]()
  # add to awaiting responses
  self.awaiting[id] = newFut

  let res = await self.transport.write(value)
  # TODO: Add actions when not full packet was send, e.g. disconnect peer.
  doAssert(res == len(value))

  return await newFut

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

method close*(client: RpcSocketClient) {.async.} =
  await client.loop.cancelAndWait()
  if not client.transport.isNil:
    client.transport.close()
    client.transport = nil
