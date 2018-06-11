include ../ eth-rpc / client
import chronicles

proc rawCall*(self: RpcClient, name: string,
           msg: string): Future[Response] {.async.} =
  # For debug purposes only
  let id = $self.nextId
  self.nextId.inc
  debug "Sending message", msg = msg
  let res = await self.transp.write(msg & "\c\l")
  debug "Receiving length assert", value = res, length = len(msg), lengthDifferent = res != len(msg)

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut

  result = await newFut
