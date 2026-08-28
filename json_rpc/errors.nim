# json-rpc
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import results, json_serialization

type
  JsonRpcError* = object of CatchableError
    ## Base type of all nim-json-rpc errors

  RpcTransportError* = object of JsonRpcError
    ## Raised when there is an issue with the underlying transport - the parent
    ## exception may be set to provide more information

  FailedHttpResponse* {.deprecated: "RpcTransportError".} = RpcTransportError
    ## Obsolete name for RpcTransportError

  ErrorResponse* = object of RpcTransportError
    status*: int
    ## Raised when the server responds with a HTTP-style error status code
    ## indicating that the call was not processed

  RpcPostError* = object of RpcTransportError
    ## raised when the underlying transport fails to send the request - the
    ## underlying client may or may not have received the request

  InvalidResponse* = object of JsonRpcError
    ## raised when the server response violates the JSON-RPC protocol
    payload*: seq[byte]

  RpcBindError* = object of JsonRpcError
  RpcAddressUnresolvableError* = object of JsonRpcError

  RequestDecodeError* = object of JsonRpcError
    ## raised when fail to decode RequestRx
    payload*: seq[byte]

  ResultDecodeError* = object of JsonRpcError
    ## raised when failing to decode the response result
    result*: JsonString

  ParamsMismatchError* = object of JsonRpcError
    ## Error raised internally when params fail to
    ## match the method signature

  RpcOrigin* {.pure.} = enum
    rpcLocal = "local"
    rpcRemote = "remote"

  RpcResponseError* = object of JsonRpcError
    ## Base error for all server error responses
    origin*: RpcOrigin
    code*: int
    data*: JsonString

  RpcParseError* = object of RpcResponseError

  RpcInvalidRequestError* = object of RpcResponseError

  RpcMethodNotFoundError* = object of RpcResponseError

  RpcInvalidParamsError* = object of RpcResponseError

  RpcInternalError* = object of RpcResponseError

  RpcServerError* = object of RpcResponseError

  RpcApplicationError* = object of RpcResponseError
    ## Error to be raised by the application request handlers when the server
    ## needs to respond with a custom application error. The error code should
    ## be outside the range of -32768 to -32000. A custom JSON data object may
    ## be provided.

  ApplicationError* {.deprecated: "RpcResponseError".} = object of JsonRpcError
    code*: int
    data*: results.Opt[JsonString]

  InvalidRequest* {.deprecated: "RpcResponseError".} = ApplicationError

# https://www.jsonrpc.org/specification#error_object
proc new*(
  T: type RpcResponseError,
  code: int,
  msg: sink string,
  data: sink JsonString = JsonString(""),
  origin: RpcOrigin = RpcOrigin.rpcLocal
): ref RpcResponseError =
  template err(obj: untyped): untyped =
    (ref obj)(origin: origin, code: code, data: move(data), msg: move(msg))

  const
    JSON_PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32603

  case code
  of JSON_PARSE_ERROR:
    err(RpcParseError)
  of INVALID_REQUEST:
    err(RpcInvalidRequestError)
  of METHOD_NOT_FOUND:
    err(RpcMethodNotFoundError)
  of INVALID_PARAMS:
    err(RpcInvalidParamsError)
  of INTERNAL_ERROR:
    err(RpcInternalError)
  else:
    if code in -32768 ..< -32099:
      err(RpcResponseError)
    elif code in -32099 .. -32000:
      err(RpcServerError)
    else:
      err(RpcApplicationError)
