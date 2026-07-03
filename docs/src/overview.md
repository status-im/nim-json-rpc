# Overview

## Protocol overview

JSON-RPC is a two-party, peer-to-peer based protocol by which one party can request a method's invocation of the other party, and optionally receive a response from the server with the result of that invocation.

Either peer may send RPC requests to the other peer. Both acting as server and client at the same time.

A common pattern is that one peer sends most of the RPC requests, while the other peer only occasionally sends requests back to the client to deliver notifications. This pattern is common in many applications because of how they are structured, not because of the JSON-RPC protocol itself or because of how this library implements it.

## json_rpc's role

`json_rpc` is a Nim library that implements the JSON-RPC protocol to easily send and receive RPC requests. It implements three main layers:

- Transport: HTTP, Sockets, and WebSocket.
- Routing: matches a request to a server method by name, invokes it, and produces a response.
- DSL: the `rpc` macro registers server methods. The `createRpcSigs` macro creates the client method calls. It automatically generates marshalling and parameter checking code based on the RPC parameter types.

## Security

The fundamental feature of the JSON-RPC protocol is the ability to request code execution of another party, including passing data either direction that may influence code execution. Neither the JSON-RPC protocol nor this library attempts to address the applicable security risks entailed.

Before establishing a JSON-RPC connection with a party that exists outside your own trust boundary, consider the threats and how to mitigate them at your application level.
