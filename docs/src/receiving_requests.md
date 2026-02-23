# Receiving a JSON-RPC request

Before receiving any request, you should have already [established a connection](./connecting.md).

When a request is received, the router matches it to a server method that was previously registered with a matching name. If no matching server method can be found the request is dropped, and an error is returned to the client if the client requested a response.

When an RPC-invoked server method throws an exception, the server will handle the exception and (when applicable) send an error response to the client with a description of the failure.

JSON-RPC is an inherently asynchronous protocol. Multiple concurrent requests are allowed. Methods are invoked as the requests are processed, even while prior requests are still running.

## Registering methods

The `rpc` macro accepts a list of proc definitions which are turned into async procedures and registered as RPC methods. Procedure overload is not supported. A format flavor supporting the parameters and return type must be set. The `RpcConv` defined in the [flavors section](./format_conversion.md) is used in the following example:

```nim
{{#shiftinclude auto:../examples/http_server.nim:RpcHello}}
```

When [named parameters](https://www.jsonrpc.org/specification#parameter_structures) are used, [`serializedFieldName`](https://github.com/status-im/nim-serialization?tab=readme-ov-file#custom-serialization-of-user-defined-types) can be used to customize the field name:

```nim
{{#shiftinclude auto:../examples/http_server.nim:RpcBye}}
```

Wrapping the method name in backticks allows any character:

```nim
{{#shiftinclude auto:../examples/http_server.nim:RpcSmile}}
```

When the procedure return type is not specified, `JsonNode` is implicitly used. To avoid returning a result, `void` can be used instead:

```nim
{{#shiftinclude auto:../examples/http_server.nim:RpcEmpty}}
```

Compiling with `-d:nimDumpRpcs` will show the output code for the RPC call. To see the output of the `async` generation, add `-d:nimDumpAsync`.

## Parameter name and placement

RPC servers should consider their methods as public API that requires stability. The following changes to a method's signature can be considered breaking:

- Renaming parameters will break clients that pass parameter by name.
- Reordering parameters will break clients that pass parameter by position.
- Removing parameters.
- Removing a method.
- Adding non-optional parameters.

The following changes to a method's signature can be considered non-breaking:

- Adding optional parameters as last parameter.
- Changing the parameter type, if it remains compatible with the wire format representation for the value.

## Throwing exceptions

RPC methods can return errors to the client by throwing an exception.

[Learn more about throwing and handling exceptions.](./exceptions.md)
