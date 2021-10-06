type
  JsonRpcError* = object of CatchableError
    ## Base type of all nim-json-rpc errors

  ErrorResponse* = object of JsonRpcError
    ## raised when the server responded with an error

  InvalidResponse* = object of JsonRpcError
    ## raised when the server response violates the JSON-RPC protocol

  RpcBindError* = object of JsonRpcError
  RpcAddressUnresolvableError* = object of JsonRpcError

  InvalidRequest* = object of JsonRpcError
    ## This could be raised by request handlers when the server
    ## needs to respond with a custom error code.
    code*: int
