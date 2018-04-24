import servertypes, cryptoutils, json, macros

var server = sharedRpcServer()

server.on("web3_clientVersion"):
  result = %"Nimbus-RPC-Test"

server.on("web3_sha3") do(data: string):
  let kres = k256(data)
  result = %kres

server.on("net_version"):
  #[ See:
    https://github.com/ethereum/interfaces/issues/6
    https://github.com/ethereum/EIPs/issues/611
  ]#
  discard

server.on("net_listening"):
  return %"true"

server.on("net_peerCount"):
  # TODO: Discovery integration
  discard

server.on("eth_protocolVersion"):
  discard

server.on("eth_syncing"):
  discard

server.on("eth_coinbase"):
  discard

server.on("eth_mining"):
  discard

server.on("eth_hashrate"):
  discard

server.on("eth_gasPrice"):
  discard

server.on("eth_accounts"):
  discard

server.on("eth_blockNumber"):
  discard

server.on("eth_getBalance") do(data: array[20, byte], quantityTag: string):
  discard

server.on("eth_getStorageAt") do(data: array[20, byte], quantity: int, quantityTag: string):
  discard

server.on("eth_getTransactionCount") do(data: array[20, byte], quantityTag: string):
  discard

server.on("eth_getBlockTransactionCountByHash") do(data: array[32, byte]):
  discard

server.on("eth_getBlockTransactionCountByNumber") do(quantityTag: string):
  discard

server.on("eth_getUncleCountByBlockHash") do(data: array[32, byte]):
  discard

server.on("eth_getUncleCountByBlockNumber") do(quantityTag: string):
  discard

server.on("eth_getCode") do(data: array[20, byte], quantityTag: string):
  discard

server.on("eth_sign") do(data: array[20, byte], message: seq[byte]):
  discard

server.on("eth_sendTransaction"): # TODO: Object
  discard

server.on("eth_sendRawTransaction") do(data: string): # TODO: string or array of byte?
  discard

server.on("eth_call"): # TODO: Object
  discard

server.on("eth_estimateGas"): # TODO: Object
  discard

server.on("eth_getBlockByHash"):
  discard

server.on("eth_getBlockByNumber"):
  discard

server.on("eth_getTransactionByHash"):
  discard

server.on("eth_getTransactionByBlockHashAndIndex"):
  discard

server.on("eth_getTransactionByBlockNumberAndIndex"):
  discard

server.on("eth_getTransactionReceipt"):
  discard

server.on("eth_getUncleByBlockHashAndIndex"):
  discard

server.on("eth_getUncleByBlockNumberAndIndex"):
  discard

server.on("eth_getCompilers"):
  discard

server.on("eth_compileLLL"):
  discard

server.on("eth_compileSolidity"):
  discard

server.on("eth_compileSerpent"):
  discard

server.on("eth_newFilter"):
  discard

server.on("eth_newBlockFilter"):
  discard

server.on("eth_newPendingTransactionFilter"):
  discard

server.on("eth_uninstallFilter"):
  discard

server.on("eth_getFilterChanges"):
  discard

server.on("eth_getFilterLogs"):
  discard

server.on("eth_getLogs"):
  discard

server.on("eth_getWork"):
  discard

server.on("eth_submitWork"):
  discard

server.on("eth_submitHashrate"):
  discard

server.on("shh_post"):
  discard

server.on("shh_version"):
  discard

server.on("shh_newIdentity"):
  discard

server.on("shh_hasIdentity"):
  discard

server.on("shh_newGroup"):
  discard

server.on("shh_addToGroup"):
  discard

server.on("shh_newFilter"):
  discard

server.on("shh_uninstallFilter"):
  discard

server.on("shh_getFilterChanges"):
  discard

server.on("shh_getMessages"):
  discard

