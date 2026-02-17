# Format conversion

The conversion to and from JSON is done using a [nim-json-serialization format](https://status-im.github.io/nim-json-serialization/reference.html#flavors). For each type used in the RPC method, a serialization declaration tells `json_rpc` how to convert it to JSON, either using defaults or by overriding `readValue` and `writeValue`.

`json_rpc` will recursively parse the Nim types in order to produce marshalling code. This marshalling code uses the types to check the incoming JSON fields to ensure they exist and are of the correct kind.

The return type then performs the opposite process, converting Nim types to JSON for transport.

## Creating a JSON flavor

The `createJsonFlavor` API accepts a flavor name and serialization options. The flavor can be passed to RPC method APIs and it will be used to convert the parameters and return value. In the following example the flavor is named `RpcConv`:

```nim
{{#shiftinclude auto:../examples/rpc_format.nim:FormatRpcConv}}
```

In the above configuration automatic object serialization is disabled. Enabling the default serialization for a given object can be done with `RpcConv.useDefaultSerializationFor(MyObject)`. This is to avoid unintentionally using the default for objects that define a custom serializer.

## Custom type serialization

It is possible to provide a custom serializer for a given type creating `writeValue` and `readValue` functions.

[Learn more about serialization in the nim-json-serialization documentation.](https://status-im.github.io/nim-json-serialization/reference.html#custom-parsers-and-writers)
