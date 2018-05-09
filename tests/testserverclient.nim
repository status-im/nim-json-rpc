import  ../ rpcserver, ../ rpcclient, unittest, asyncdispatch, json, tables

#[
  TODO: Importing client before server causes the error:
  Error: undeclared identifier: 'result' for the `myProc` RPC.
  This is because the RPC procs created by clientdispatch clash with ethprocs.
  Currently, easiest solution is to import rpcserver (and therefore generate 
  ethprocs) before rpcclient.
]#
# TODO: dummy implementations of RPC calls handled in async fashion.
# TODO: check required json parameters like version are being raised
var srv = sharedRpcServer()
srv.address = "localhost"
srv.port = Port(8545)

srv.on("myProc") do(input: string, data: array[0..3, int]):
  result = %("Hello " & input & " data: " & $data)

asyncCheck srv.serve

suite "RPC":
  proc main {.async.} =
    var client = newRpcClient()
    await client.connect("localhost", Port(8545))
    var response: Response
    test "Version":
      response = waitFor client.web3_clientVersion(newJNull())
      check response.result == %"Nimbus-RPC-Test"
    test "SHA3":
      response = waitFor client.web3_sha3(%["abc"])
      check response.result.getStr == "3A985DA74FE225B2045C172D6BD390BD855F086E3E9D525B46BFE24511431532"
    test "Custom RPC":
      # Custom async RPC call
      response = waitFor client.call("myProc", %[%"abc", %[1, 2, 3, 4]])
      check response.result.getStr == "Hello abc data: [1, 2, 3, 4]"

  waitFor main()
  