import ../src/rpcclient, asyncdispatch, json

when isMainModule:
  proc main {.async.} =
    var client = newRpcClient()
    await client.connect("localhost", Port(8545))
    var
      response: Response

    for i in 0..1000:
      response = waitFor client.web3_clientVersion(newJNull())
  waitFor main()
  echo "Finished."