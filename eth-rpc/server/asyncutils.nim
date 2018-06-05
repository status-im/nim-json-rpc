import json, asyncdispatch, asyncnet, jsonutils, private / debugutils

proc wrapReply*(id: JsonNode, value: JsonNode, error: JsonNode): string =
  let node = %{"jsonrpc": %"2.0", "result": value, "error": error, "id": id}
  return $node & "\c\l" 

proc sendError*(client: AsyncSocket, code: int, msg: string, id: JsonNode, data: JsonNode = newJNull()) {.async.} =
  ## Send error message to client
  let error = %{"code": %(code), "message": %msg, "data": data}
  ifDebug: echo "Send error json: ", wrapReply(newJNull(), error, id)
  result = client.send(wrapReply(id, newJNull(), error))

proc sendJsonError*(state: RpcJsonError, client: AsyncSocket, id: JsonNode, data = newJNull()) {.async.} =
  ## Send client response for invalid json state
  let errMsgs = jsonErrorMessages[state]
  await client.sendError(errMsgs[0], errMsgs[1], id, data)
