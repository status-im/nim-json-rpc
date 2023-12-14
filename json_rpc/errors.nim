# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

type
  JsonRpcError* = object of CatchableError
    ## Base type of all nim-json-rpc errors

  ErrorResponse* = object of JsonRpcError
    status*: int
    ## raised when the server responded with an error

  InvalidResponse* = object of JsonRpcError
    ## raised when the server response violates the JSON-RPC protocol

  FailedHttpResponse* = object of JsonRpcError
    ## raised when fail to read the underlying HTTP server response

  RpcPostError* = object of JsonRpcError
    ## raised when the client fails to send the POST request with JSON-RPC

  RpcBindError* = object of JsonRpcError
  RpcAddressUnresolvableError* = object of JsonRpcError

  InvalidRequest* = object of JsonRpcError
    ## This could be raised by request handlers when the server
    ## needs to respond with a custom error code.
    code*: int
