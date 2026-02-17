# Adding Remote RPC Targets

There are scenarios where users may need to add remote RPC targets to facilitate communication between two endpoints that have no direct RPC connection channel. Consider the following 3 endpoints:

- client
- server
- remote

There is a direct RPC connection between client and server, and server and remote. However, client and remote may need to send messages to each other as well. To do so, users can use an RPC proxy server.

## Create a proxy server

The proxy server only supports HTTP to serve clients. It supports HTTP and Websockets to connect to the remote server:

HTTP:

```nim
{{#shiftinclude auto:../examples/proxy_server.nim:ServerConnect}}
```

Websockets:

```nim
var proxy = RpcProxy.new(["127.0.0.1:0"], getWebSocketClientConfig("ws://" & $srv.localAddress()))
```

## Registering remote target methods

The client can only make a call to the remote endpoint if the proxy (what's in the middle) has registered the remote RPC method:

```nim
{{#shiftinclude auto:../examples/proxy_server.nim:ProxyHello}}
```

## Registering methods

The proxy server can register its own RPC methods:

```nim
{{#shiftinclude auto:../examples/proxy_server.nim:RpcBye}}
```

## Start the proxy server

After registering the RPC methods, the server can start serving clients:

```nim
{{#shiftinclude auto:../examples/proxy_server.nim:ServerStart}}
```

Then usually `runForever()` or `waitFor` a program termination signal `waitSignal(SIGINT)`. This will run the Chronos async event loop until the program is terminated.
