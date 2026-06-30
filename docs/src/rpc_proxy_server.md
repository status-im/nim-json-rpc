# RPC Proxy Server

A proxy server can register methods which will be served by another server. In this case there will be a connection between `client`-`proxy-server` and `proxy-server`-`server`. Some methods can be served directly by the `proxy-server`, while the proxy methods are forwarded to the `server`.

## Create a proxy server

The proxy-server only supports HTTP to serve clients. It supports HTTP and Websockets to connect to the server:

HTTP:

```nim
{{#shiftinclude auto:../examples/proxy_server.nim:ServerConnect}}
```

Websockets:

```nim
var proxy = RpcProxy.new(["127.0.0.1:0"], getWebSocketClientConfig("ws://" & $srv.localAddress()))
```

## Registering proxy methods

The client can only make a call to the server endpoint if the proxy (what's in the middle) has registered the RPC proxy method:

```nim
{{#shiftinclude auto:../examples/proxy_server.nim:ProxyHello}}
```

## Registering methods

The proxy-server can register its own RPC methods:

```nim
{{#shiftinclude auto:../examples/proxy_server.nim:RpcBye}}
```

## Start the proxy server

After registering the RPC methods, the proxy-server can start serving clients:

```nim
{{#shiftinclude auto:../examples/proxy_server.nim:ServerStart}}
```

Then usually `runForever()` or `waitFor` a program termination signal `waitSignal(SIGINT)`. This will run the Chronos async event loop until the program is terminated.
