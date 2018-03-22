import ../eth-rpc/rpcserver, asyncdispatch

when isMainModule:
  echo "Initialising server..."
  # create on localhost, default port
  var srv = newRpcServer("")
  echo "Server started."
  asyncCheck srv.serve()
  runForever()

  echo "Server stopped."