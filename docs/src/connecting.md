# Establishing a JSON-RPC connection

A JSON-RPC connection communicates over an existing transport, such as HTTP, Sockets and pipes, and Websockets:

- HTTP POST: unidirectional, one request/response pair per call.
- Sockets and pipes, via [chronos](https://github.com/status-im/nim-chronos)' `StreamTransport`: bidirectional, persistent connection, custom message framing.
  - `Framing.httpHeader`: `Content-Length` prefix specifying the length of the payload, compatible with [vscode-jsonrpc](https://www.npmjs.com/package/vscode-jsonrpc).
  - `Framing.lengthHeaderBE32`: Big-endian, 32-bit binary prefix - most efficient option.
- Websockets: bidirectional, persistent connection.

## Server (and possibly client also)

Create the server instance using one of the available transports:

HTTP:

```nim
{{#shiftinclude auto:../examples/http_server.nim:ServerConnect}}
```

Sockets:

```nim
{{#shiftinclude auto:../examples/socket_server.nim:ServerConnect}}
```

Websockets:

```nim
{{#shiftinclude auto:../examples/websocket_server.nim:ServerConnect}}
```

After [registering the RPC methods](./receiving_requests.md), the server can start serving clients:

```nim
{{#shiftinclude auto:../examples/http_server.nim:RpcHttpServerStart}}
```

Then usually `runForever()` or `waitFor` a program termination signal `waitSignal(SIGINT)`. This will run the Chronos async event loop until the program is terminated.

## Client

Create the client instance using one of the available transports:

HTTP:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientConnect}}
```

Sockets:

```nim
{{#shiftinclude auto:../examples/socket_client.nim:ClientConnect}}
```

Websockets:

```nim
{{#shiftinclude auto:../examples/websocket_client.nim:ClientConnect}}
```

You can then [proceed to send requests](./sending_requests.md).

## Disconnecting

Close the client connection:

```nim
{{#shiftinclude auto:../examples/http_client.nim:ClientDisconnect}}
```

Stop the RPC server and clean-up resources:

```nim
{{#shiftinclude auto:../examples/http_server.nim:ServerDisconnect}}
```
