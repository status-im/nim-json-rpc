import json, asyncdispatch, asyncnet, jsonutils, private / debugutils

proc wrapReply*(id: JsonNode, value: JsonNode, error: JsonNode): JsonNode =
  return %{"jsonrpc": %"2.0", "result": value, "error": error, "id": id}

proc sendError*(client: AsyncSocket, code: int, msg: string, id: JsonNode, data: JsonNode = newJNull()) {.async.} =
  ## Send error message to client
  let error = %{"code": %(code), "message": %msg, "data": data}
  ifDebug: echo "Send error json: ", wrapReply(newJNull(), error, id).pretty & "\c\l"
  # REVIEW: prefer in-place appending instead of string concatenation
  # (see the similar comment in clientdispatch.nim)
  result = client.send($wrapReply(id, newJNull(), error) & "\c\l")

proc sendJsonError*(state: RpcJsonError, client: AsyncSocket, id: JsonNode, data = newJNull()) {.async.} =
  ## Send client response for invalid json state
  let errMsgs = jsonErrorMessages[state]
  await client.sendError(errMsgs[0], errMsgs[1], id, data)
