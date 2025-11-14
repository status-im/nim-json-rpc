# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/uri,
  chronos/apps/http/httpclient,
  httputils,
  ../[client, errors]

export client, errors, HttpClientFlag, HttpClientFlags

type
  HttpClientOptions* = object
    httpMethod: HttpMethod

  RpcHttpClient* = ref object of RpcClient
    httpSession: HttpSessionRef
    httpAddress: HttpAddress
    getHeaders: GetJsonRpcRequestHeaders

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

  T(
    maxMessageSize: maxMessageSize,
    httpSession: HttpSessionRef.new(flags = flags + moreFlags),
    getHeaders: getHeaders,
  )

method request(
    client: RpcHttpClient, reqData: seq[byte]
): Future[seq[byte]] {.async: (raises: [CancelledError, JsonRpcError]).} =
  doAssert client.httpSession != nil
  if client.httpAddress.addresses.len == 0:
    raise newException(RpcTransportError, "No remote addresses to connect to")

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

    let
      resData = await res.getBodyBytes(client.maxMessageSize)
      # TODO remove this processMessage hook when subscriptions / pubsub is
      #      properly supported
      fallback = client.callOnProcessMessage(resData).valueOr:
        raise (ref RequestDecodeError)(msg: error, payload: resData)

    if not fallback:
      # TODO http channels are unidirectional, so it doesn't really make sense
      #      to call onProcessMessage from http - this should be deprecated
      #      as soon as bidirectionality is supported
      raise (ref InvalidResponse)(msg: "onProcessMessage handled response")

    resData
  except HttpError as exc:
    raise (ref RpcTransportError)(msg: exc.msg, parent: exc)
  finally:
    await req.closeWait()

proc newRpcHttpClient*(
    maxBodySize = defaultMaxMessageSize,
    secure = false,
    getHeaders: GetJsonRpcRequestHeaders = nil,
    flags: HttpClientFlags = {},
): RpcHttpClient =
  RpcHttpClient.new(secure, getHeaders, flags, maxBodySize)

proc connect*(
    client: RpcHttpClient, url: string
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  client.httpAddress = client.httpSession.getAddress(url).valueOr:
    raise newException(RpcAddressUnresolvableError, error)
  client.remote = client.httpAddress.id

proc connect*(
    client: RpcHttpClient, address: string, port: Port, secure: bool
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  let uri = Uri(
    scheme: if secure: "https" else: "http",
    hostname: address,
    port: $port)

  client.httpAddress = getAddress(client.httpSession, uri).valueOr:
    raise newException(RpcAddressUnresolvableError, error)
  client.remote = client.httpAddress.id

method close*(client: RpcHttpClient) {.async: (raises: []).} =
  if not client.httpSession.isNil:
    await client.httpSession.closeWait()

{.pop.}
