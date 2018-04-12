import ../eth-rpc / rpcclient, ../eth-rpc / rpcserver, 
  asyncdispatch, json, unittest, tables

# REVIEW: I'd like to see some dummy implementations of RPC calls handled in async fashion.
proc myProc* {.rpc.} =
  # Custom async RPC call
  return %"Hello"

var srv = newRpcServer("")
# This is required to automatically register `myProc` to new servers
registerRpcs(srv)
asyncCheck srv.serve
# TODO: Avoid having to add procs twice, once for the ethprocs in newRpcServer,
# and again with the extra `myProc` rpc
when isMainModule:
  # create on localhost, default port
  suite "RPC":
    proc main {.async.} =
      var client = newRpcClient()
      await client.connect("localhost", Port(8545))
      var response: Response

      test "Version":
        response = waitFor client.web3_clientVersion(newJNull())
        check response.result == %"Nimbus-RPC-Test"
      test "SHA3":
        response = waitFor client.web3_sha3(%"abc")
        check response.result.getStr == "3A985DA74FE225B2045C172D6BD390BD855F086E3E9D525B46BFE24511431532"
      test "Custom RPC":
        response = waitFor client.call("myProc", %"abc")
        check response.result.getStr == "Hello"
      

    waitFor main()
    