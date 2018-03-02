import servertypes, json, asyncdispatch, macros

macro rpc*(prc: untyped): untyped =
  result = prc
  let params = prc.findChild(it.kind == nnkFormalParams)
  assert params != nil
  for param in params.children:
    if param.kind == nnkIdentDefs:
      if param[1] == ident("JsonNode"):
        return
  var identDefs = newNimNode(nnkIdentDefs)
  identDefs.add ident("params"), ident("JsonNode"), newEmptyNode()
  # proc result
  # check there isn't already a result type
  assert params.len == 1 and params[0].kind == nnkEmpty
  params[0] = ident("JsonNode")
  params.add identDefs
  # finally, register with server's table.
  # this requires a server variable to be passed somehow
  
  #var body = prc.findChild(it.kind == nnkStmtList)
  #body.add(quote do:
  #  server.register "web3_clientVersion", web3_clientVersion
  #)


proc web3_clientVersion {.rpc.} =
  return %("Nimbus-RPC-Test")

proc web3_sha3 {.rpc.} =
  discard

proc net_version {.rpc.} =
  discard

proc net_peerCount {.rpc.} =
  discard

proc net_listening {.rpc.} =
  discard

proc eth_protocolVersion {.rpc.} =
  discard

proc eth_syncing {.rpc.} =
  discard

proc eth_coinbase {.rpc.} =
  discard

proc eth_mining {.rpc.} =
  discard

proc eth_hashrate {.rpc.} =
  discard

proc eth_gasPrice {.rpc.} =
  discard

proc eth_accounts {.rpc.} =
  discard

proc eth_blockNumber {.rpc.} =
  discard

proc eth_getBalance {.rpc.} =
  discard

proc eth_getStorageAt {.rpc.} =
  discard

proc eth_getTransactionCount {.rpc.} =
  discard

proc eth_getBlockTransactionCountByHash {.rpc.} =
  discard

proc eth_getBlockTransactionCountByNumber {.rpc.} =
  discard

proc eth_getUncleCountByBlockHash {.rpc.} =
  discard

proc eth_getUncleCountByBlockNumber {.rpc.} =
  discard

proc eth_getCode {.rpc.} =
  discard

proc eth_sign {.rpc.} =
  discard

proc eth_sendTransaction {.rpc.} =
  discard

proc eth_sendRawTransaction {.rpc.} =
  discard

proc eth_call {.rpc.} =
  discard

proc eth_estimateGas {.rpc.} =
  discard

proc eth_getBlockByHash {.rpc.} =
  discard

proc eth_getBlockByNumber {.rpc.} =
  discard

proc eth_getTransactionByHash {.rpc.} =
  discard

proc eth_getTransactionByBlockHashAndIndex {.rpc.} =
  discard

proc eth_getTransactionByBlockNumberAndIndex {.rpc.} =
  discard

proc eth_getTransactionReceipt {.rpc.} =
  discard

proc eth_getUncleByBlockHashAndIndex {.rpc.} =
  discard

proc eth_getUncleByBlockNumberAndIndex {.rpc.} =
  discard

proc eth_getCompilers {.rpc.} =
  discard

proc eth_compileLLL {.rpc.} =
  discard

proc eth_compileSolidity {.rpc.} =
  discard

proc eth_compileSerpent {.rpc.} =
  discard

proc eth_newFilter {.rpc.} =
  discard

proc eth_newBlockFilter {.rpc.} =
  discard

proc eth_newPendingTransactionFilter {.rpc.} =
  discard

proc eth_uninstallFilter {.rpc.} =
  discard

proc eth_getFilterChanges {.rpc.} =
  discard

proc eth_getFilterLogs {.rpc.} =
  discard

proc eth_getLogs {.rpc.} =
  discard

proc eth_getWork {.rpc.} =
  discard

proc eth_submitWork {.rpc.} =
  discard

proc eth_submitHashrate {.rpc.} =
  discard

proc db_putString {.rpc.} =
  discard

proc db_getString {.rpc.} =
  discard

proc db_putHex {.rpc.} =
  discard

proc db_getHex {.rpc.} =
  discard

proc shh_post {.rpc.} =
  discard

proc shh_version {.rpc.} =
  discard

proc shh_newIdentity {.rpc.} =
  discard

proc shh_hasIdentity {.rpc.} =
  discard

proc shh_newGroup {.rpc.} =
  discard

proc shh_addToGroup {.rpc.} =
  discard

proc shh_newFilter {.rpc.} =
  discard

proc shh_uninstallFilter {.rpc.} =
  discard

proc shh_getFilterChanges {.rpc.} =
  discard

proc shh_getMessages {.rpc.} =
  discard

proc registerEthereumRpcs*(server: RpcServer) =
  ## Register all ethereum rpc calls to the server
  # TODO: Automate this
  server.register "web3_clientVersion", web3_clientVersion
  server.register "web3_sha3", web3_sha3
  server.register "net_version", net_version
  server.register "net_peerCount", net_peerCount
  server.register "net_listening", net_listening
  server.register "eth_protocolVersion", eth_protocolVersion
  server.register "eth_syncing", eth_syncing
  server.register "eth_coinbase", eth_coinbase
  server.register "eth_mining", eth_mining
  server.register "eth_hashrate", eth_hashrate
  server.register "eth_gasPrice", eth_gasPrice
  server.register "eth_accounts", eth_accounts
  server.register "eth_blockNumber", eth_blockNumber
  server.register "eth_getBalance", eth_getBalance
  server.register "eth_getStorageAt", eth_getStorageAt
  server.register "eth_getTransactionCount", eth_getTransactionCount
  server.register "eth_getBlockTransactionCountByHash", eth_getBlockTransactionCountByHash
  server.register "eth_getBlockTransactionCountByNumber", eth_getBlockTransactionCountByNumber
  server.register "eth_getUncleCountByBlockHash", eth_getUncleCountByBlockHash
  server.register "eth_getUncleCountByBlockNumber", eth_getUncleCountByBlockNumber
  server.register "eth_getCode", eth_getCode
  server.register "eth_sign", eth_sign
  server.register "eth_sendTransaction", eth_sendTransaction
  server.register "eth_sendRawTransaction", eth_sendRawTransaction
  server.register "eth_call", eth_call
  server.register "eth_estimateGas", eth_estimateGas
  server.register "eth_getBlockByHash", eth_getBlockByHash
  server.register "eth_getBlockByNumber", eth_getBlockByNumber
  server.register "eth_getTransactionByHash", eth_getTransactionByHash
  server.register "eth_getTransactionByBlockHashAndIndex", eth_getTransactionByBlockHashAndIndex
  server.register "eth_getTransactionByBlockNumberAndIndex", eth_getTransactionByBlockNumberAndIndex
  server.register "eth_getTransactionReceipt", eth_getTransactionReceipt
  server.register "eth_getUncleByBlockHashAndIndex", eth_getUncleByBlockHashAndIndex
  server.register "eth_getUncleByBlockNumberAndIndex", eth_getUncleByBlockNumberAndIndex
  server.register "eth_getCompilers", eth_getCompilers
  server.register "eth_compileLLL", eth_compileLLL
  server.register "eth_compileSolidity", eth_compileSolidity
  server.register "eth_compileSerpent", eth_compileSerpent
  server.register "eth_newFilter", eth_newFilter
  server.register "eth_newBlockFilter", eth_newBlockFilter
  server.register "eth_newPendingTransactionFilter", eth_newPendingTransactionFilter
  server.register "eth_uninstallFilter", eth_uninstallFilter
  server.register "eth_getFilterChanges", eth_getFilterChanges
  server.register "eth_getFilterLogs", eth_getFilterLogs
  server.register "eth_getLogs", eth_getLogs
  server.register "eth_getWork", eth_getWork
  server.register "eth_submitWork", eth_submitWork
  server.register "eth_submitHashrate", eth_submitHashrate
  server.register "db_putString", db_putString
  server.register "db_getString", db_getString
  server.register "db_putHex", db_putHex
  server.register "db_getHex", db_getHex
  server.register "shh_post", shh_post
  server.register "shh_version", shh_version
  server.register "shh_newIdentity", shh_newIdentity
  server.register "shh_hasIdentity", shh_hasIdentity
  server.register "shh_newGroup", shh_newGroup
  server.register "shh_addToGroup", shh_addToGroup
  server.register "shh_newFilter", shh_newFilter
  server.register "shh_uninstallFilter", shh_uninstallFilter
  server.register "shh_getFilterChanges", shh_getFilterChanges
  server.register "shh_getMessages", shh_getMessages      

