# Throwing and handling exceptions

The JSON-RPC protocol allows for server methods to return errors to the client instead of a result, except when the client invoked the method as a notification.

The [structure JSON-RPC defines for errors](https://www.jsonrpc.org/specification#response_object) includes an error code and a message.

Error codes -32768 to -32000 are reserved for the protocol itself or for the library that implements it. The rest of the 32-bit integer range of the error code is available for the application to define. This error code is the best way for an RPC server to communicate a particular kind of error that the RPC client may use for controlling execution flow. For example the server may use an error code to indicate a conflict and another code to indicate a permission denied error. The client may check this error code and branch execution based on its value.

The error *message* should be a localized, human readable message that explains the problem, possibly to the programmer of the RPC client or perhaps to the end user of the application.

JSON-RPC also allows for an error `data` property which may be a primitive value, array or object that provides more data regarding the error. The schema for this property is up to the application.

## Server-side concerns

The RPC server can return errors to the client by throwing an exception from the RPC method. If the RPC method was invoked using a JSON-RPC notification, the client is not expecting any response and the exception thrown from the server will be swallowed.

The RPC method can raise an `ApplicationError` with a specific `code`, `data`, and `msg` (message). Any other exception thrown from an RPC method is assigned -32000 (Server error) for the JSON-RPC error `code` property. The exception `msg` field is used as the JSON-RPC error `data` property.

RPC method error example:

```nim
{{#shiftinclude auto:../examples/http_server.nim:RpcTeaPot}}
```

## Client-side concerns

An invocation of an RPC method may throw several exceptions back at the client. The base exception `JsonRpcError` can be used to catch all RPC exceptions.

These are the exceptions which the client should be prepared to handle: `RpcTransportError`, `InvalidResponse`, `RequestDecodeError`, and `JsonRpcError`.

The JSON error object is assigned to the `msg` field of `JsonRpcError`, when it does not match the rest of exceptions.

Error handling example:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientTeaPot}}
```
