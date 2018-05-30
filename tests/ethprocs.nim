import ../rpcserver, nimcrypto, json, stint, strutils, ethtypes, stintjsonconverters

#[
  For details on available RPC calls, see: https://github.com/ethereum/wiki/wiki/JSON-RPC
  Note that many of the calls return hashes and even 'ints' as hex strings.
  This module will likely have to be split into smaller sections for ease of use.

  Information:
    Default block parameter: https://github.com/ethereum/wiki/wiki/JSON-RPC#the-default-block-parameter

  Parameter types
    Changes might be required for parameter types.
    For example:
      * String might be more appropriate than seq[byte], for example for addresses, although would need length constraints.
      * Int return values might actually be more hex string than int.
      * array[32, byte] could be UInt256 or Int256, but default to UInt256.
      * EthTypes such as BlockObject and TransactionObject might be better as existing Nimbus objects if present.

  NOTE:
    * as `from` is a keyword, this has been replaced with `source` for variable names. TODO: Related - eplace `to` with `dest`?

  TODO:
    * Some values can be returned as different types (eg, int or bool)
      * Currently implemented as variant types, but server macros need to support
        initialisation of these types before any use as `kind` can only be
        specified once without invoking `reset`.
]#

var server = sharedRpcServer()

server.rpc("web3_clientVersion") do() -> string:
  ## Returns the current client version.
  result = "Nimbus-RPC-Test"

server.rpc("web3_sha3") do(data: string) -> string:
  ## Returns Keccak-256 (not the standardized SHA3-256) of the given data.
  ##
  ## data: the data to convert into a SHA3 hash.
  ## Returns the SHA3 result of the given string.
  # TODO: Capture error on malformed input
  var rawData: seq[byte]
  if data.len > 2 and data[0] == '0' and data[1] in ['x', 'X']:
    rawData = data[2..data.high].fromHex
  else:
    rawData = data.fromHex
  # data will have 0x prefix
  result = "0x" & $keccak_256.digest(rawData)

server.rpc("net_version") do() -> string:
  ## Returns string of the current network id:
  ## "1": Ethereum Mainnet
  ## "2": Morden Testnet (deprecated)
  ## "3": Ropsten Testnet
  ## "4": Rinkeby Testnet
  ## "42": Kovan Testnet
  #[ Note, See:
    https://github.com/ethereum/interfaces/issues/6
    https://github.com/ethereum/EIPs/issues/611
  ]#
  result = ""

server.rpc("net_listening") do() -> bool:
  ## Returns boolean true when listening, otherwise false.
  result = true

server.rpc("net_peerCount") do() -> int:
  ## Returns integer of the number of connected peers.
  discard

server.rpc("eth_protocolVersion") do() -> string:
  ## Returns string of the current ethereum protocol version.
  discard

server.rpc("eth_syncing") do() -> JsonNode:
  ## Returns SyncObject or false when not syncing.
  var
    res: JsonNode
    sync: SyncObject
  if true: res = %sync
  else: res = newJBool(false)
  result = res

server.rpc("eth_coinbase") do() -> string:
  ## Returns the current coinbase address.
  result = ""

server.rpc("eth_mining") do() -> bool:
  ## Returns true of the client is mining, otherwise false.
  discard

server.rpc("eth_hashrate") do() -> int:
  ## Returns the number of hashes per second that the node is mining with.
  discard

server.rpc("eth_gasPrice") do() -> int64:
  ## Returns an integer of the current gas price in wei.
  discard

server.rpc("eth_accounts") do() -> seq[array[20, byte]]:
  ## Returns a list of addresses owned by client.
  # TODO: this might be easier to use as seq[string]
  # This is what's expected: "result": ["0x407d73d8a49eeb85d32cf465507dd71d507100c1"]
  discard

server.rpc("eth_blockNumber") do() -> int:
  ## Returns integer of the current block number the client is on.
  discard

server.rpc("eth_getBalance") do(data: array[20, byte], quantityTag: string) -> int:
  ## Returns the balance of the account of given address.
  ##
  ## data: address to check for balance.
  ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns integer of the current balance in wei.
  discard

server.rpc("eth_getStorageAt") do(data: array[20, byte], quantity: int, quantityTag: string) -> seq[byte]:
  ## Returns the value from a storage position at a given address.
  ##
  ## data: address of the storage.
  ## quantity: integer of the position in the storage.
  ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns: the value at this storage position.
  # TODO: More appropriate return type?
  # For more details, see: https://github.com/ethereum/wiki/wiki/JSON-RPC#eth_getstorageat
  result = @[]

server.rpc("eth_getTransactionCount") do(data: array[20, byte], quantityTag: string):
  ## Returns the number of transactions sent from an address.
  ##
  ## data: address.
  ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns integer of the number of transactions send from this address.
  discard

server.rpc("eth_getBlockTransactionCountByHash") do(data: array[32, byte]) -> int:
  ## Returns the number of transactions in a block from a block matching the given block hash.
  ##
  ## data: hash of a block
  ## Returns integer of the number of transactions in this block.
  discard

server.rpc("eth_getBlockTransactionCountByNumber") do(quantityTag: string) -> int:
  ## Returns the number of transactions in a block matching the given block number.
  ##
  ## data: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
  ## Returns integer of the number of transactions in this block.
  discard

server.rpc("eth_getUncleCountByBlockHash") do(data: array[32, byte]):
  ## Returns the number of uncles in a block from a block matching the given block hash.
  ##
  ## data: hash of a block.
  ## Returns integer of the number of uncles in this block.
  discard

server.rpc("eth_getUncleCountByBlockNumber") do(quantityTag: string):
  ## Returns the number of uncles in a block from a block matching the given block number.
  ##
  ## quantityTag: integer of a block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns integer of uncles in this block.
  discard

server.rpc("eth_getCode") do(data: array[20, byte], quantityTag: string) -> seq[byte]:
  ## Returns code at a given address.
  ##
  ## data: address
  ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns the code from the given address.
  result = @[]

server.rpc("eth_sign") do(data: array[20, byte], message: seq[byte]) -> seq[byte]:
  ## The sign method calculates an Ethereum specific signature with: sign(keccak256("\x19Ethereum Signed Message:\n" + len(message) + message))).
  ## By adding a prefix to the message makes the calculated signature recognisable as an Ethereum specific signature.
  ## This prevents misuse where a malicious DApp can sign arbitrary data (e.g. transaction) and use the signature to impersonate the victim.
  ## Note the address to sign with must be unlocked.
  ##
  ## data: address.
  ## message: message to sign.
  ## Returns signature.
  discard

server.rpc("eth_sendTransaction") do(obj: EthSend) -> UInt256:
  ## Creates new message call transaction or a contract creation, if the data field contains code.
  ##
  ## obj: the transaction object.
  ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
  ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
  discard

server.rpc("eth_sendRawTransaction") do(data: string, quantityTag: int) -> UInt256: # TODO: string or array of byte?
  ## Creates new message call transaction or a contract creation for signed transactions.
  ##
  ## data: the signed transaction data.
  ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
  ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
  discard

server.rpc("eth_call") do(call: EthCall, quantityTag: string) -> UInt256:
  ## Executes a new message call immediately without creating a transaction on the block chain.
  ##
  ## call: the transaction call object.
  ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns the return value of executed contract.
  # TODO: Should return value be UInt256 or seq[byte] or string?
  discard

server.rpc("eth_estimateGas") do(call: EthCall, quantityTag: string) -> UInt256: # TODO: Int or U/Int256?
  ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
  ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
  ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
  ## 
  ## call: the transaction call object.
  ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns the amount of gas used.
  discard

server.rpc("eth_getBlockByHash") do(data: array[32, byte], fullTransactions: bool) -> BlockObject:
  ## Returns information about a block by hash.
  ##
  ## data: Hash of a block.
  ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
  ## Returns BlockObject or nil when no block was found.
  discard

server.rpc("eth_getBlockByNumber") do(quantityTag: string, fullTransactions: bool) -> BlockObject:
  ## Returns information about a block by block number.
  ##
  ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
  ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
  ## Returns BlockObject or nil when no block was found.
  discard

server.rpc("eth_getTransactionByHash") do(data: Uint256) -> TransactionObject:
  ## Returns the information about a transaction requested by transaction hash.
  ##
  ## data: hash of a transaction.
  ## Returns requested transaction information.
  discard

server.rpc("eth_getTransactionByBlockHashAndIndex") do(data: UInt256, quantity: int) -> TransactionObject:
  ## Returns information about a transaction by block hash and transaction index position.
  ##
  ## data: hash of a block.
  ## quantity: integer of the transaction index position.
  ## Returns  requested transaction information.
  discard

server.rpc("eth_getTransactionByBlockNumberAndIndex") do(quantityTag: string, quantity: int) -> TransactionObject:
  ## Returns information about a transaction by block number and transaction index position.
  ##
  ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
  ## quantity: the transaction index position.
  discard

server.rpc("eth_getTransactionReceipt") do(data: UInt256) -> ReceiptObject:
  ## Returns the receipt of a transaction by transaction hash.
  ##
  ## data: hash of a transaction.
  ## Returns transaction receipt.
  discard

server.rpc("eth_getUncleByBlockHashAndIndex") do(data: UInt256, quantity: int64) -> BlockObject:
  ## Returns information about a uncle of a block by hash and uncle index position.  
  ##
  ## data: hash a block.
  ## quantity: the uncle's index position.
  ## Returns BlockObject or nil when no block was found.
  discard

server.rpc("eth_getUncleByBlockNumberAndIndex") do(quantityTag: string, quantity: int64) -> BlockObject:
  # Returns information about a uncle of a block by number and uncle index position.
  ##
  ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
  ## quantity: the uncle's index position.
  ## Returns BlockObject or nil when no block was found.
  discard

server.rpc("eth_getCompilers") do() -> seq[string]:
  ## Returns a list of available compilers in the client.
  ##
  ## Returns a list of available compilers.
  result = @[]

server.rpc("eth_compileSolidity") do(sourceCode: string) -> seq[byte]:
  ## Returns compiled solidity code.
  ##
  ## sourceCode: source code as string.
  ## Returns compiles source code.
  result = @[]

server.rpc("eth_compileLLL") do(sourceCode: string) -> seq[byte]:
  ## Returns compiled LLL code.
  ##
  ## sourceCode: source code as string.
  ## Returns compiles source code.
  result = @[]

server.rpc("eth_compileSerpent") do(sourceCode: string) -> seq[byte]:
  ## Returns compiled serpent code.
  ##
  ## sourceCode: source code as string.
  ## Returns compiles source code.
  result = @[]

server.rpc("eth_newFilter") do(filterOptions: FilterOptions) -> int:
  ## Creates a filter object, based on filter options, to notify when the state changes (logs).
  ## To check if the state has changed, call eth_getFilterChanges.
  ## Topics are order-dependent. A transaction with a log with topics [A, B] will be matched by the following topic filters:
  ## [] "anything"
  ## [A] "A in first position (and anything after)"
  ## [null, B] "anything in first position AND B in second position (and anything after)"
  ## [A, B] "A in first position AND B in second position (and anything after)"
  ## [[A, B], [A, B]] "(A OR B) in first position AND (A OR B) in second position (and anything after)"  
  ##
  ## filterOptions: settings for this filter.
  ## Returns integer filter id.
  discard

server.rpc("eth_newBlockFilter") do() -> int:
  ## Creates a filter in the node, to notify when a new block arrives.
  ## To check if the state has changed, call eth_getFilterChanges.
  ##
  ## Returns integer filter id.
  discard

server.rpc("eth_newPendingTransactionFilter") do() -> int:
  ## Creates a filter in the node, to notify when a new block arrives.
  ## To check if the state has changed, call eth_getFilterChanges.
  ##
  ## Returns integer filter id.
  discard

server.rpc("eth_uninstallFilter") do(filterId: int) -> bool:
  ## Uninstalls a filter with given id. Should always be called when watch is no longer needed. 
  ## Additonally Filters timeout when they aren't requested with eth_getFilterChanges for a period of time.
  ##
  ## filterId: The filter id.
  ## Returns true if the filter was successfully uninstalled, otherwise false.
  discard

server.rpc("eth_getFilterChanges") do(filterId: int) -> seq[LogObject]:
  ## Polling method for a filter, which returns an list of logs which occurred since last poll.
  ##
  ## filterId: the filter id.
  result = @[]

server.rpc("eth_getFilterLogs") do(filterId: int) -> seq[LogObject]:
  ## filterId: the filter id.
  ## Returns a list of all logs matching filter with given id.
  result = @[]

server.rpc("eth_getLogs") do(filterOptions: FilterOptions) -> seq[LogObject]:
  ## filterOptions: settings for this filter.
  ## Returns a list of all logs matching a given filter object.
  result = @[]

server.rpc("eth_getWork") do() -> seq[UInt256]:
  ## Returns the hash of the current block, the seedHash, and the boundary condition to be met ("target").
  ## Returned list has the following properties:
  ## DATA, 32 Bytes - current block header pow-hash.
  ## DATA, 32 Bytes - the seed hash used for the DAG.
  ## DATA, 32 Bytes - the boundary condition ("target"), 2^256 / difficulty.
  result = @[]

server.rpc("eth_submitWork") do(nonce: int64, powHash: Uint256, mixDigest: Uint256) -> bool:
  ## Used for submitting a proof-of-work solution.
  ##
  ## nonce: the nonce found.
  ## headerPow: the header's pow-hash.
  ## mixDigest: the mix digest.
  ## Returns true if the provided solution is valid, otherwise false.
  discard

server.rpc("eth_submitHashrate") do(hashRate: UInt256, id: Uint256) -> bool:
  ## Used for submitting mining hashrate.
  ##
  ## hashRate: a hexadecimal string representation (32 bytes) of the hash rate.
  ## id: a random hexadecimal(32 bytes) ID identifying the client.
  ## Returns true if submitting went through succesfully and false otherwise.
  discard

server.rpc("shh_version") do() -> string:
  ## Returns string of the current whisper protocol version.
  discard

server.rpc("shh_post") do(message: WhisperPost) -> bool:
  ## Sends a whisper message.
  ##
  ## message: Whisper message to post.
  ## Returns true if the message was send, otherwise false.
  discard

server.rpc("shh_newIdentity") do() -> array[60, byte]:
  ## Creates new whisper identity in the client.
  ##
  ## Returns the address of the new identiy.
  discard

server.rpc("shh_hasIdentity") do(identity: array[60, byte]) -> bool:
  ## Checks if the client holds the private keys for a given identity.
  ##
  ## identity: the identity address to check.
  ## Returns true if the client holds the privatekey for that identity, otherwise false.
  discard

server.rpc("shh_newGroup") do() -> array[60, byte]:
  ## (?) - This has no description information in the RPC wiki.
  ##
  ## Returns the address of the new group. (?)
  discard

server.rpc("shh_addToGroup") do(identity: array[60, byte]) -> bool:
  ## (?) - This has no description information in the RPC wiki.
  ##
  ## identity: the identity address to add to a group (?).
  ## Returns true if the identity was successfully added to the group, otherwise false (?).
  discard

server.rpc("shh_newFilter") do(filterOptions: FilterOptions, to: array[60, byte], topics: seq[UInt256]) -> int: # TODO: Is topic of right type?
  ## Creates filter to notify, when client receives whisper message matching the filter options.
  ##
  ## filterOptions: The filter options:
  ## to: DATA, 60 Bytes - (optional) identity of the receiver. When present it will try to decrypt any incoming message if the client holds the private key to this identity.
  ## topics: Array of DATA - list of DATA topics which the incoming message's topics should match. You can use the following combinations:
  ## [A, B] = A && B
  ## [A, [B, C]] = A && (B || C)
  ## [null, A, B] = ANYTHING && A && B null works as a wildcard
  ## Returns the newly created filter.
  discard

server.rpc("shh_uninstallFilter") do(id: int) -> bool:
  ## Uninstalls a filter with given id.
  ## Should always be called when watch is no longer needed.
  ## Additonally Filters timeout when they aren't requested with shh_getFilterChanges for a period of time.
  ##
  ## id: the filter id.
  ## Returns true if the filter was successfully uninstalled, otherwise false.
  discard

server.rpc("shh_getFilterChanges") do(id: int) -> seq[WhisperMessage]:
  ## Polling method for whisper filters. Returns new messages since the last call of this method.
  ## Note: calling the shh_getMessages method, will reset the buffer for this method, so that you won't receive duplicate messages.
  ##
  ## id: the filter id.
  discard

server.rpc("shh_getMessages") do(id: int) -> seq[WhisperMessage]:
  ## Get all messages matching a filter. Unlike shh_getFilterChanges this returns all messages.
  ##
  ## id: the filter id.
  ## Returns a list of messages received since last poll.
  discard

