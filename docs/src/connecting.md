# Establishing a JSON-RPC connection

## Transports

A JSON-RPC connection communicates over an existing transport, such as HTTP, Sockets and pipes, and Websockets:

- HTTP POST: unidirectional, one request/response pair per call.
- Sockets and pipes, via [chronos](https://github.com/status-im/nim-chronos)' `StreamTransport`: bidirectional, persistent connection, custom message framing.
  - `Framing.httpHeader`: `Content-Length` prefix specifying the length of the payload, compatible with [vscode-jsonrpc](https://www.npmjs.com/package/vscode-jsonrpc).
  - `Framing.lengthHeaderBE32`: Big-endian, 32-bit binary prefix - most efficient option.
- Standard input/output: the same bidirectional connection and framing as sockets, but over the process' own stdin/stdout, or over those of a child process. This is the transport [LSP](https://microsoft.github.io/language-server-protocol/) and [MCP](https://modelcontextprotocol.io/) servers are launched with; `StdioFraming.httpHeader` is its default framing and the one those peers expect.
- Websockets: bidirectional, persistent connection.

```admonish warning
Over standard input/output, stdout carries the protocol: anything else written
to it corrupts the message stream. Chronicles - which `json_rpc` itself logs
through - writes to stdout unless told otherwise, so build stdio programs with
the sinks pointed at stderr, and keep `echo` out of them:

    -d:"chronicles_sinks=textlines[stderr]"

Note that this applies to every log level, debug output included.
```

A program can refuse to build without the switch, which turns a corrupted
message stream into a compile error:

```nim
{{#shiftinclude auto:../examples/stdio_server.nim:ServerLogging}}
```

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

Standard input/output:

```nim
{{#shiftinclude auto:../examples/stdio_server.nim:ServerConnect}}
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

Standard input/output - either over this process' own stdin/stdout, or by
launching the peer, which is how an editor starts a language server:

```nim
import json_rpc/clients/stdioclient

const framing = StdioFraming.httpHeader()

# Speak JSON-RPC over this process' own stdin/stdout ...
let client = newRpcStdioClient(framing = framing)
client.connect()

# ... or spawn the peer and speak it over the child's stdin/stdout
let child = newRpcStdioClient(framing = framing)
await child.connect("my-language-server", @["--stdio"])
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

A stdio client that spawned its peer closes it the same way; the child sees
end of file on its standard input, and `close` waits for it to exit:

```nim
await child.close()
doAssert child.exitCode() == Opt.some(0)
```

Stop the RPC server and clean-up resources:

```nim
{{#shiftinclude auto:../examples/http_server.nim:ServerDisconnect}}
```
