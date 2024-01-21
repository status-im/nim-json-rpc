# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, uri],
  stew/byteutils,
  results,
  chronos/apps/http/httpclient as chronosHttpClient,
  chronicles, httputils, json_serialization/std/net,
  ../client,
  ../errors,
  ../private/jrpc_sys

export
  client, HttpClientFlag, HttpClientFlags

logScope:
  topics = "JSONRPC-HTTP-CLIENT"

type
  HttpClientOptions* = object
    httpMethod: HttpMethod

  RpcHttpClient* = ref object of RpcClient
    httpSession: HttpSessionRef
    httpAddress: HttpResult[HttpAddress]
    maxBodySize: int
    getHeaders: GetJsonRpcRequestHeaders

const
  MaxHttpRequestSize = 128 * 1024 * 1024 # maximum size of HTTP body in octets

{.push gcsafe, raises: [].}

proc new(
    T: type RpcHttpClient, maxBodySize = MaxHttpRequestSize, secure = false,
    getHeaders: GetJsonRpcRequestHeaders = nil, flags: HttpClientFlags = {}): T =

  var moreFlags: HttpClientFlags
  if secure:
    moreFlags.incl HttpClientFlag.NoVerifyHost
    moreFlags.incl HttpClientFlag.NoVerifyServerName

  T(
    maxBodySize: maxBodySize,
    httpSession: HttpSessionRef.new(flags = flags + moreFlags),
    getHeaders: getHeaders
  )

proc newRpcHttpClient*(
    maxBodySize = MaxHttpRequestSize, secure = false,
    getHeaders: GetJsonRpcRequestHeaders = nil,
    flags: HttpClientFlags = {}): RpcHttpClient =
  RpcHttpClient.new(maxBodySize, secure, getHeaders, flags)

method call*(client: RpcHttpClient, name: string,
             params: RequestParamsTx): Future[JsonString]
            {.async, gcsafe.} =
  doAssert client.httpSession != nil
  if client.httpAddress.isErr:
    raise newException(RpcAddressUnresolvableError, client.httpAddress.error)

  var headers =
    if not isNil(client.getHeaders):
      client.getHeaders()
    else:
      @[]
  headers.add(("Content-Type", "application/json"))

  let
    id = client.getNextId()
    reqBody = requestTxEncode(name, params, id)

  var req: HttpClientRequestRef
  var res: HttpClientResponseRef

  template used(x: typed) =
    # silence unused warning
    discard

  template closeRefs() =
    # We can't trust try/finally in async/await in all nim versions, so we
    # do it manually instead
    if req != nil:
      try:
        await req.closeWait()
      except CatchableError as exc: # shouldn't happen
        used(exc)
        debug "Error closing JSON-RPC HTTP resuest/response", err = exc.msg
    if res != nil:
      try:
        await res.closeWait()
      except CatchableError as exc: # shouldn't happen
        used(exc)
        debug "Error closing JSON-RPC HTTP resuest/response", err = exc.msg

  debug "Sending message to RPC server",
         address = client.httpAddress, msg_len = len(reqBody), name
  trace "Message", msg = reqBody

  req = HttpClientRequestRef.post(client.httpSession,
                                  client.httpAddress.get,
                                  body = reqBody.toOpenArrayByte(0, reqBody.len - 1),
                                  headers = headers)
  res =
    try:
      await req.send()
    except CancelledError as e:
      debug "Cancelled POST Request with JSON-RPC", e = e.msg
      closeRefs()
      raise e
    except CatchableError as e:
      debug "Failed to send POST Request with JSON-RPC", e = e.msg
      closeRefs()
      raise (ref RpcPostError)(msg: "Failed to send POST Request with JSON-RPC: " & e.msg, parent: e)

  if res.status < 200 or res.status >= 300: # res.status is not 2xx (success)
    debug "Unsuccessful POST Request with JSON-RPC",
      status = res.status, reason = res.reason
    closeRefs()
    raise (ref ErrorResponse)(status: res.status, msg: res.reason)

  let resBytes =
    try:
      await res.getBodyBytes(client.maxBodySize)
    except CancelledError as e:
      debug "Cancelled POST Response for JSON-RPC", e = e.msg
      closeRefs()
      raise e
    except CatchableError as e:
      debug "Failed to read POST Response for JSON-RPC", e = e.msg
      closeRefs()
      raise (ref FailedHttpResponse)(msg: "Failed to read POST Response for JSON-RPC: " & e.msg, parent: e)

  let resText = string.fromBytes(resBytes)
  trace "Response", text = resText

  # completed by processMessage - the flow is quite weird here to accomodate
  # socket and ws clients, but could use a more thorough refactoring
  var newFut = newFuture[JsonString]()
  # add to awaiting responses
  client.awaiting[id] = newFut

  # Might error for all kinds of reasons
  let msgRes = client.processMessage(resText)
  if msgRes.isErr:
    # Need to clean up in case the answer was invalid
    debug "Failed to process POST Response for JSON-RPC", msg = msgRes.error
    newFut.cancelSoon()
    client.awaiting.del(id)
    closeRefs()
    raise newException(JsonRpcError, msgRes.error)

  client.awaiting.del(id)

  closeRefs()

  # processMessage should have completed this future - if it didn't, `read` will
  # raise, which is reasonable
  if newFut.finished:
    return newFut.read()
  else:
    # TODO: Provide more clarity regarding the failure here
    debug "Invalid POST Response for JSON-RPC"
    raise newException(InvalidResponse, "Invalid response")

proc connect*(client: RpcHttpClient, url: string) {.async.} =
  client.httpAddress = client.httpSession.getAddress(url)
  if client.httpAddress.isErr:
    raise newException(RpcAddressUnresolvableError, client.httpAddress.error)

proc connect*(client: RpcHttpClient, address: string, port: Port, secure: bool) {.async.} =
  var uri = Uri(
    scheme: if secure: "https" else: "http",
    hostname: address,
    port: $port)

  let res = getAddress(client.httpSession, uri)
  if res.isOk:
    client.httpAddress = res
  else:
    raise newException(RpcAddressUnresolvableError, res.error)

method close*(client: RpcHttpClient) {.async.} =
  if not client.httpSession.isNil:
    await client.httpSession.closeWait()

{.pop.}
