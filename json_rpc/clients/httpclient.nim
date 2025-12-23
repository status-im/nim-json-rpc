# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import std/uri, chronos/apps/http/httpclient, httputils, ../[client, errors]

export client, errors, HttpClientFlag, HttpClientFlags

type
  HttpClientOptions* = object
    httpMethod: HttpMethod

  RpcHttpClient* = ref object of RpcClient
    httpSession: HttpSessionRef
    httpAddress: HttpAddress
    getHeaders: GetJsonRpcRequestHeaders
    flags: HttpClientFlags

proc new*(
    T: type RpcHttpClient,
    secure = false,
    getHeaders: GetJsonRpcRequestHeaders = nil,
    flags: HttpClientFlags = {},
    maxMessageSize = defaultMaxMessageSize,
): T =
  var moreFlags: HttpClientFlags
  if secure:
    moreFlags.incl HttpClientFlag.NoVerifyHost
    moreFlags.incl HttpClientFlag.NoVerifyServerName

  T(maxMessageSize: maxMessageSize, getHeaders: getHeaders, flags: flags + moreFlags)

proc newRpcHttpClient*(
    maxBodySize = defaultMaxMessageSize,
    secure = false,
    getHeaders: GetJsonRpcRequestHeaders = nil,
    flags: HttpClientFlags = {},
): RpcHttpClient =
  RpcHttpClient.new(secure, getHeaders, flags, maxBodySize)

method send(
    client: RpcHttpClient, reqData: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  if client.httpSession.isNil:
    raise newException(RpcTransportError, "Not connected")

  var headers =
    if not isNil(client.getHeaders):
      client.getHeaders()
    else:
      @[]
  headers.add(("Content-Type", "application/json"))

  let
    req = HttpClientRequestRef.post(
      client.httpSession, client.httpAddress, body = reqData, headers = headers
    )

    res =
      try:
        await req.send()
      except HttpError as exc:
        raise (ref RpcPostError)(msg: exc.msg, parent: exc)
      finally:
        await req.closeWait()

  try:
    if res.status < 200 or res.status >= 300: # res.status is not 2xx (success)
      raise (ref ErrorResponse)(status: res.status, msg: res.reason)
  except HttpError as exc:
    raise (ref RpcTransportError)(msg: exc.msg, parent: exc)
  finally:
    await res.closeWait()

method request(
    client: RpcHttpClient, reqData: seq[byte]
): Future[seq[byte]] {.async: (raises: [CancelledError, JsonRpcError]).} =
  doAssert reqData.len > 0, "request must not be empty"
  if client.httpSession.isNil:
    raise newException(RpcTransportError, "Not connected")

  var headers =
    if not isNil(client.getHeaders):
      client.getHeaders()
    else:
      @[]
  headers.add(("Content-Type", "application/json"))

  let
    req = HttpClientRequestRef.post(
      client.httpSession, client.httpAddress, body = reqData, headers = headers
    )

    res =
      try:
        await req.send()
      except HttpError as exc:
        raise (ref RpcPostError)(msg: exc.msg, parent: exc)
      finally:
        await req.closeWait()

  try:
    if res.status < 200 or res.status >= 300: # res.status is not 2xx (success)
      raise (ref ErrorResponse)(status: res.status, msg: res.reason)

    await res.getBodyBytes(client.maxMessageSize)
  except HttpError as exc:
    raise (ref RpcTransportError)(msg: exc.msg, parent: exc)
  finally:
    await res.closeWait()

proc connect*(
    client: RpcHttpClient, url: string
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  client.httpSession = HttpSessionRef.new(flags = client.flags)
  client.httpAddress = client.httpSession.getAddress(url).valueOr:
    raise newException(RpcAddressUnresolvableError, error)
  client.remote = client.httpAddress.id

proc connect*(
    client: RpcHttpClient, address: string, port: Port, secure: bool
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  let uri = Uri(scheme: if secure: "https" else: "http", hostname: address, port: $port)

  client.httpSession = HttpSessionRef.new(flags = client.flags)
  client.httpAddress = getAddress(client.httpSession, uri).valueOr:
    raise newException(RpcAddressUnresolvableError, error)
  client.remote = client.httpAddress.id

method close*(client: RpcHttpClient) {.async: (raises: []).} =
  if client.httpSession != nil:
    let httpSession = move(client.httpSession)
    await httpSession.closeWait()

{.pop.}
