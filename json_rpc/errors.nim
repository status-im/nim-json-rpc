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

  RpcBindError* = object of JsonRpcError
  RpcAddressUnresolvableError* = object of JsonRpcError

  InvalidRequest* = object of JsonRpcError
    ## raised when the server recieves an invalid JSON request object
    code*: int

  RequestDecodeError* = object of JsonRpcError
    ## raised when fail to decode RequestRx
    payload*: seq[byte]

  ApplicationError* = object of JsonRpcError
    ## Error to be raised by the application request handlers when the server
    ## needs to respond with a custom application error. The error code should
    ## be outside the range of -32768 to -32000. A custom JSON data object may
    ## be provided.
    code*: int
    data*: results.Opt[JsonString]
