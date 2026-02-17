# Sending a JSON-RPC request

Before sending any request, you should have already [established a connection](./connecting.md).

## Requests and notifications

Within the JSON-RPC specification, a client request can specify whether a reply from the server is required. If no reply is expected, the message is a *notification*. Because notifications do not generate responses, the client receives no confirmation that the server received the request, processed it successfully, encountered an error, or produced any output.

A notification should not be used just because a method does not return a value. Even when a method has no return data, using the standard request-response model ensures the client can detect failures or execution errors on the server side.

## Argument arrays vs. an argument object

The JSON-RPC protocol passes arguments from client to server using either an array or as a single JSON object with a property for each parameter on the target method. Essentially, this leads to argument-to-parameter matching by position or by name.

Most JSON-RPC servers expect an array. `json_rpc` supports passing arguments both as a parameter object and in an array.

## Invoking methods using compile-time definitions

The `createRpcSigsFromNim` macro accepts a list of forward procedure declarations and it generates the client RPCs. The `RpcConv` defined in the [flavors section](./format_conversion.md) is used in the following example:

```nim
{{#shiftinclude auto:../examples/http_client.nim:RpcHello}}
```

Wrapping the method name in backticks allows any character:

```nim
{{#shiftinclude auto:../examples/http_client.nim:RpcSmile}}
```

The RPC method can be invoked using a client instance with a stablished connection:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientRequest}}
```

The `createRpcSigs` macro accepts the path of a file containing a list of forward proc declarations and it generates the client RPCs of it:

```nim
{{#shiftinclude auto:../examples/http_client_sigs.nim:ClientFileSigs}}
```

The `createSingleRpcSig` macro accepts a single forward proc declaration and an alias. The alias can be used to invoke the RPC method:

```nim
{{#shiftinclude auto:../examples/http_client_sigs.nim:ClientSingleSig}}
```

The `createRpcSigsFromString` macro accepts a string containing a list of forward proc declarations and it generates the client RPCs:

```nim
const rpcClientDefs = staticRead(sigsFilePath)
createRpcSigsFromString(RpcClient, rpcClientDefs, RpcConv)
```

## Invoking methods using runtime information

An RPC method can be invoked passing its name an parameter types at runtime. The parameter must be passed as a `JsonNode` or `RequestParamsTx`. The `RpcConv` defined in the flavors section is used in the following example:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientRequestRuntime}}
```

Using named parameters is allowed. Some server implementations may support only positional parameters, `json_rpc` supports both styles:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientRequestNamedRuntime}}
```

When the method doesn't take parameters, it can be invoked passing an empty array:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientRequestNoParamsRuntime}}
```

The response from `call` is a `JsonString` which can be decoded using [json_serialization](https://github.com/status-im/nim-json-serialization):

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientResponseDecode}}
```

## Sending batch requests

The JSON-RPC specification [allows for batching](https://www.jsonrpc.org/specification#batch) requests and getting a response containing an array of responses for each request.

The `prepareBatch` client function can be used to batch requests and `send` them all at once:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientBatch}}
```

The `send` return value is an optional result with either the sequence of RPC responses, or an error indicating there was an error processing the array of responses. Each response contains a `result` or an `error`. The result field is the JSON encoded RPC `result`. If the optional error field is set, it'll contain either an error message or the JSON encoded RPC `error` response:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientBatchResult}}
```

## Sending a notification

A notification can be sent for fire and forget method invocations. As mentioned earlier, the method response is not returned, and the client is not notified about server errors:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientNotification}}
```

## Exception handling

RPC methods may throw exceptions. The RPC client should be prepared to handle these exceptions.

[Learn more about throwing and handling exceptions.](./exceptions.md)
