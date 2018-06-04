**Json-rpc**

[![Build Status (Travis)](https://img.shields.io/travis/status-im/nim-eth-rpc/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/status-im/nim-eth-rpc)
[![Windows build status (Appveyor)](https://img.shields.io/appveyor/ci/jarradh/nim-eth-rpc/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/jarradh/nim-eth-rpc)

Json-Rpc is designed to provide an easier interface for working with remote procedure calls.

# Installation

`git clone https://github.com/status-im/nim-eth-rpc`


## Requirements
* Nim 17.3 and up


# Usage

## Server

Remote procedure calls are created using the `rpc` macro.
This macro allows you to provide a list of native Nim type parameters and a return type, and will automatically handle all the marshalling to and from json for you, so you can concentrate on using native Nim types for your call.

Here's a full example of a server with a single RPC.

```nim
import rpcserver

var srv = newRpcServer("")

# Create an RPC with a string an array parameter, that returns an int
srv.rpc("myProc") do(input: int, data: array[0..3, int]) -> string:
  result = "Hello " & $input & " data: " & $data

asyncCheck srv.serve()
runForever()
```

Parameter types are recursively traversed so you can use any custom types you wish, even nested types. Ref and object types are fully supported.

```nim
type
  Details = ref object
    values: seq[byte]

  Payload = object
    x, y: float
    count: int
    details: Details
  
  ResultData = object
    data: array[10, byte]

srv.rpc("getResults") do(payload: Payload) -> ResultData:
  # Here we can use Payload as expected, and `result` will be of type ResultData.
  # Parameters and results are automatically converted to and from json
  # and the call is intrinsically asynchronous.
  
```

Behind the scenes, all RPC calls take a single json parameter that must be defined as a `JArray`.
At runtime, the json is checked to ensure that it contains the correct number and type of your parameters to match the `rpc` definition.
The `rpc` macro takes care of the boiler plate in marshalling to and from json.

Compiling with `-d:nimDumpRpcs` will show the output code for the RPC call.

The following RPC:

```nim
srv.rpc("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)
```
Will get transformed into something like this:

```nim
proc myProc*(params: JsonNode): Future[JsonNode] {.async.} =
  params.kind.expect(JArray, "params")
  if params.len != 2:
    raise newException(ValueError, "Expected 2 Json parameter(s) but got " &
        $params.len)
  var input: string
  input = unpackArg(params.elems[0], "input", type(string))
  var data: array[0 .. 3, int]
  data = unpackArg(params.elems[1], "data", type(array[0 .. 3, int]))
  result = %("Hello " & input & " data: " & $data)
```

## Client

Below is the most basic way to use a remote call on the client.
Here we manually supply the name and json parameters for the call. 

```nim
import rpcclient, asyncdispatch, json

proc main =
  var client = newRpcClient()
  await client.connect("localhost", Port(8545))
  let response = waitFor client.call("myRpc", %[])
  # the call returns a `Response` type which contains the result
  echo response.result.pretty

waitFor main()
```

To make things more readable and allow better checking client side, Json-Rpc supports generating wrappers for client RPCs using `createRpcSigs`.

This macro takes the path of a file containing forward declarations of procedures that you wish to convert to client RPCs.
Because the signatures are parsed at compile time, the file will be error checked and you can use import to share common types between your client and server. 

For example, to support this remote call:

```nim
server.rpc("bmi") do(height, weight: float) -> float:
  result = (height * height) / weight
```

You can have the following in your rpc signature file:

```nim
proc bmi(height, weight: float): float
```

When parsed through `createRpcSigs`, you can call the RPC as if it were a normal procedure.
So instead of this:

```nim
let bmiIndex = await client.call("bmi", %[%120.5, %12.0])
```

You can use:

```nim
let bmiIndex = await client.bmi(120.5, 12.0)
```


# Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.

# License
[MIT](https://choosealicense.com/licenses/mit/)