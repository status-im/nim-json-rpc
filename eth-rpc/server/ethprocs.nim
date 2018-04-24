import servertypes, cryptoutils, json, macros

var s = sharedRpcServer()

s.on("web3_clientVersion"):
  result = %"Nimbus-RPC-Test"

s.on("web3_sha3") do(input: string):
  let kres = k256(input)
  result = %kres

proc net_version* {.rpc.} =
  #[ See:
    https://github.com/ethereum/interfaces/issues/6
    https://github.com/ethereum/EIPs/issues/611
  ]#
  discard

proc net_listening* {.rpc.} =
  return %"true"

proc net_peerCount* {.rpc.} =
  # TODO: Discovery integration
  discard

proc eth_protocolVersion* {.rpc.} =
  discard

proc eth_syncing* {.rpc.} =
  discard

proc eth_coinbase* {.rpc.} =
  discard

proc eth_mining* {.rpc.} =
  discard

proc eth_hashrate* {.rpc.} =
  discard

proc eth_gasPrice* {.rpc.} =
  discard

proc eth_accounts* {.rpc.} =
  discard

proc eth_blockNumber* {.rpc.} =
  discard

proc eth_getBalance* {.rpc.} =
  discard

proc eth_getStorageAt* {.rpc.} =
  discard

proc eth_getTransactionCount* {.rpc.} =
  discard

proc eth_getBlockTransactionCountByHash* {.rpc.} =
  discard

proc eth_getBlockTransactionCountByNumber* {.rpc.} =
  discard

proc eth_getUncleCountByBlockHash* {.rpc.} =
  discard

proc eth_getUncleCountByBlockNumber* {.rpc.} =
  discard

proc eth_getCode* {.rpc.} =
  discard

proc eth_sign* {.rpc.} =
  discard

proc eth_sendTransaction* {.rpc.} =
  discard

proc eth_sendRawTransaction* {.rpc.} =
  discard

proc eth_call* {.rpc.} =
  discard

proc eth_estimateGas* {.rpc.} =
  discard

proc eth_getBlockByHash* {.rpc.} =
  discard

proc eth_getBlockByNumber* {.rpc.} =
  discard

proc eth_getTransactionByHash* {.rpc.} =
  discard

proc eth_getTransactionByBlockHashAndIndex* {.rpc.} =
  discard

proc eth_getTransactionByBlockNumberAndIndex* {.rpc.} =
  discard

proc eth_getTransactionReceipt* {.rpc.} =
  discard

proc eth_getUncleByBlockHashAndIndex* {.rpc.} =
  discard

proc eth_getUncleByBlockNumberAndIndex* {.rpc.} =
  discard

proc eth_getCompilers* {.rpc.} =
  discard

proc eth_compileLLL* {.rpc.} =
  discard

proc eth_compileSolidity* {.rpc.} =
  discard

proc eth_compileSerpent* {.rpc.} =
  discard

proc eth_newFilter* {.rpc.} =
  discard

proc eth_newBlockFilter* {.rpc.} =
  discard

proc eth_newPendingTransactionFilter* {.rpc.} =
  discard

proc eth_uninstallFilter* {.rpc.} =
  discard

proc eth_getFilterChanges* {.rpc.} =
  discard

proc eth_getFilterLogs* {.rpc.} =
  discard

proc eth_getLogs* {.rpc.} =
  discard

proc eth_getWork* {.rpc.} =
  discard

proc eth_submitWork* {.rpc.} =
  discard

proc eth_submitHashrate* {.rpc.} =
  discard

proc shh_post* {.rpc.} =
  discard

proc shh_version* {.rpc.} =
  discard

proc shh_newIdentity* {.rpc.} =
  discard

proc shh_hasIdentity* {.rpc.} =
  discard

proc shh_newGroup* {.rpc.} =
  discard

proc shh_addToGroup* {.rpc.} =
  discard

proc shh_newFilter* {.rpc.} =
  discard

proc shh_uninstallFilter* {.rpc.} =
  discard

proc shh_getFilterChanges* {.rpc.} =
  discard

proc shh_getMessages* {.rpc.} =
  discard

