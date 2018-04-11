import ../eth-rpc / rpcclient, ../eth-rpc / rpcserver, asyncdispatch, json, unittest, ../eth-rpc/server/ethprocs

# REVIEW: I'd like to see some dummy implementations of RPC calls handled in async fashion.
proc myProc {.rpc.} =
  return %"hello"

when isMainModule:
  # create on localhost, default port
  var srv = newRpcServer("")
  registerEthereumRpcs(srv)
  asyncCheck srv.serve()

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
      response = waitFor client.call("myProc", %"abc")
      echo response.result.getStr
      

    waitFor main()
