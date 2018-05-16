import servertypes, cryptoutils, json, stint

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
        * It might be worth replacing array[X, byte] with the equivilent stInt/stUInt.
      * Int return values might actually be more hex string than int.
      * UInt256/Int256
      * Objects such as BlockObject and TransactionObject might be better as the existing Nimbus objects

  NOTE:
    * as `from` is a keyword, this has been replaced with `source` for variable names.

  TODO:
    * Check UInt256 is being converted correctly as input

]#

var server = sharedRpcServer()

server.on("web3_clientVersion"):
  ## Returns the current client version.
  result = %"Nimbus-RPC-Test"

server.on("web3_sha3") do(data: string) -> string:
  ## Returns Keccak-256 (not the standardized SHA3-256) of the given data.
  ##
  ## data: the data to convert into a SHA3 hash.
  ## Returns the SHA3 result of the given string.
  result = k256(data)

server.on("net_version"):
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
  discard

server.on("net_listening") do() -> bool:
  ## Returns boolean true when listening, otherwise false.
  result = true

server.on("net_peerCount") do() -> int:
  ## Returns integer of the number of connected peers.
  discard

server.on("eth_protocolVersion") do() -> string:
  ## Returns string of the current ethereum protocol version.
  discard

type
  SyncObject = object
    startingBlock: int
    currentBlock: int
    highestBlock: int

server.on("eth_syncing") do() -> JsonNode:
  ## Returns SyncObject or false when not syncing.
  var
    res: JsonNode
    sync: SyncObject
  if true: res = %sync
  else: res = newJBool(false)
  result = res

server.on("eth_coinbase") do() -> string:
  ## Returns the current coinbase address.
  discard

server.on("eth_mining") do() -> bool:
  ## Returns true of the client is mining, otherwise false.
  discard

server.on("eth_hashrate") do() -> int:
  ## Returns the number of hashes per second that the node is mining with.
  discard

server.on("eth_gasPrice") do() -> int64:
  ## Returns an integer of the current gas price in wei.
  discard

server.on("eth_accounts") do() -> seq[array[20, byte]]:
  ## Returns a list of addresses owned by client.
  # TODO: this might be easier to use as seq[string]
  # This is what's expected: "result": ["0x407d73d8a49eeb85d32cf465507dd71d507100c1"]
  discard

server.on("eth_blockNumber") do() -> int:
  ## Returns integer of the current block number the client is on.
  discard

server.on("eth_getBalance") do(data: array[20, byte], quantityTag: string) -> int:
  ## Returns the balance of the account of given address.
  ##
  ## data: address to check for balance.
  ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns integer of the current balance in wei.
  discard

server.on("eth_getStorageAt") do(data: array[20, byte], quantity: int, quantityTag: string) -> seq[byte]:
  ## Returns the value from a storage position at a given address.
  ##
  ## data: address of the storage.
  ## quantity: integer of the position in the storage.
  ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns: the value at this storage position.
  # TODO: More appropriate return type?
  # For more details, see: https://github.com/ethereum/wiki/wiki/JSON-RPC#eth_getstorageat
  result = @[]

server.on("eth_getTransactionCount") do(data: array[20, byte], quantityTag: string):
  ## Returns the number of transactions sent from an address.
  ##
  ## data: address.
  ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns integer of the number of transactions send from this address.
  discard

server.on("eth_getBlockTransactionCountByHash") do(data: array[32, byte]) -> int:
  ## Returns the number of transactions in a block from a block matching the given block hash.
  ##
  ## data: hash of a block
  ## Returns integer of the number of transactions in this block.
  discard

server.on("eth_getBlockTransactionCountByNumber") do(quantityTag: string) -> int:
  ## Returns the number of transactions in a block matching the given block number.
  ##
  ## data: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
  ## Returns integer of the number of transactions in this block.
  discard

server.on("eth_getUncleCountByBlockHash") do(data: array[32, byte]):
  ## Returns the number of uncles in a block from a block matching the given block hash.
  ##
  ## data: hash of a block.
  ## Returns integer of the number of uncles in this block.
  discard

server.on("eth_getUncleCountByBlockNumber") do(quantityTag: string):
  ## Returns the number of uncles in a block from a block matching the given block number.
  ##
  ## quantityTag: integer of a block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns integer of uncles in this block.
  discard

server.on("eth_getCode") do(data: array[20, byte], quantityTag: string) -> seq[byte]:
  ## Returns code at a given address.
  ##
  ## data: address
  ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns the code from the given address.
  result = @[]

server.on("eth_sign") do(data: array[20, byte], message: seq[byte]) -> seq[byte]:
  ## The sign method calculates an Ethereum specific signature with: sign(keccak256("\x19Ethereum Signed Message:\n" + len(message) + message))).
  ## By adding a prefix to the message makes the calculated signature recognisable as an Ethereum specific signature.
  ## This prevents misuse where a malicious DApp can sign arbitrary data (e.g. transaction) and use the signature to impersonate the victim.
  ## Note the address to sign with must be unlocked.
  ##
  ## data: address.
  ## message: message to sign.
  ## Returns signature.
  discard

type EthSend = object
  source: array[20, byte] # the address the transaction is send from.
  to: array[20, byte]     # (optional when creating new contract) the address the transaction is directed to.
  gas: int                # (optional, default: 90000) integer of the gas provided for the transaction execution. It will return unused gas.
  gasPrice: int           # (optional, default: To-Be-Determined) integer of the gasPrice used for each paid gas.
  value: int              # (optional) integer of the value sent with this transaction.
  data: int               # the compiled code of a contract OR the hash of the invoked method signature and encoded parameters. For details see Ethereum Contract ABI.
  nonce: int              # (optional) integer of a nonce. This allows to overwrite your own pending transactions that use the same nonce.

server.on("eth_sendTransaction") do(obj: EthSend) -> UInt256:
  ## Creates new message call transaction or a contract creation, if the data field contains code.
  ##
  ## obj: the transaction object.
  ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
  ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
  discard

server.on("eth_sendRawTransaction") do(data: string, quantityTag: int) -> UInt256: # TODO: string or array of byte?
  ## Creates new message call transaction or a contract creation for signed transactions.
  ##
  ## data: the signed transaction data.
  ## Returns the transaction hash, or the zero hash if the transaction is not yet available.
  ## Note: Use eth_getTransactionReceipt to get the contract address, after the transaction was mined, when you created a contract.
  discard

type EthCall = object
  source: array[20, byte] # (optional) The address the transaction is send from.
  to: array[20, byte]     # The address the transaction is directed to.
  gas: int                # (optional) Integer of the gas provided for the transaction execution. eth_call consumes zero gas, but this parameter may be needed by some executions.
  gasPrice: int           # (optional) Integer of the gasPrice used for each paid gas.
  value: int              # (optional) Integer of the value sent with this transaction.
  data: int               # (optional) Hash of the method signature and encoded parameters. For details see Ethereum Contract ABI.

server.on("eth_call") do(call: EthCall, quantityTag: string) -> UInt256:
  ## Executes a new message call immediately without creating a transaction on the block chain.
  ##
  ## call: the transaction call object.
  ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns the return value of executed contract.
  # TODO: Should return value be UInt256 or seq[byte] or string?
  discard

server.on("eth_estimateGas") do(call: EthCall, quantityTag: string) -> UInt256: # TODO: Int or U/Int256?
  ## Generates and returns an estimate of how much gas is necessary to allow the transaction to complete.
  ## The transaction will not be added to the blockchain. Note that the estimate may be significantly more than
  ## the amount of gas actually used by the transaction, for a variety of reasons including EVM mechanics and node performance.
  ## 
  ## call: the transaction call object.
  ## quantityTag:  integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
  ## Returns the amount of gas used.
  discard

type
  ## A block object, or null when no block was found
  BlockObject = ref object
    number: int                   # the block number. null when its pending block.
    hash: UInt256                 # hash of the block. null when its pending block.
    parentHash: UInt256           # hash of the parent block.
    nonce: int64                  # hash of the generated proof-of-work. null when its pending block.
    sha3Uncles: UInt256           # SHA3 of the uncles data in the block.
    logsBloom: array[256, byte]   # the bloom filter for the logs of the block. null when its pending block.
    transactionsRoot: UInt256     # the root of the transaction trie of the block.
    stateRoot: UInt256            # the root of the final state trie of the block.
    receiptsRoot: UInt256         # the root of the receipts trie of the block.
    miner: array[20, byte]        # the address of the beneficiary to whom the mining rewards were given.
    difficulty: int               # integer of the difficulty for this block.
    totalDifficulty: int          # integer of the total difficulty of the chain until this block.
    extraData: string             # the "extra data" field of this block.
    size: int                     # integer the size of this block in bytes.
    gasLimit: int                 # the maximum gas allowed in this block.
    gasUsed: int                  # the total used gas by all transactions in this block.
    timestamp: int                # the unix timestamp for when the block was collated.
    transactions: seq[Uint256]    # list of transaction objects, or 32 Bytes transaction hashes depending on the last given parameter.
    uncles: seq[Uint256]          # list of uncle hashes.

server.on("eth_getBlockByHash") do(data: array[32, byte], fullTransactions: bool) -> BlockObject:
  ## Returns information about a block by hash.
  ##
  ## data: Hash of a block.
  ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
  ## Returns BlockObject or nil when no block was found.
  discard

server.on("eth_getBlockByNumber") do(quantityTag: string, fullTransactions: bool) -> BlockObject:
  ## Returns information about a block by block number.
  ##
  ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
  ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
  ## Returns BlockObject or nil when no block was found.
  discard

type
  TransactionObject = object  # A transaction object, or null when no transaction was found:
    hash: UInt256             # hash of the transaction.
    nonce: int64              # TODO: Is int? the number of transactions made by the sender prior to this one.
    blockHash: UInt256        # hash of the block where this transaction was in. null when its pending.
    blockNumber: int64        # block number where this transaction was in. null when its pending.
    transactionIndex: int64   # integer of the transactions index position in the block. null when its pending.
    source: array[20, byte]   # address of the sender.
    to: array[20, byte]       # address of the receiver. null when its a contract creation transaction.
    value: int64              # value transferred in Wei.
    gasPrice: int64           # gas price provided by the sender in Wei.
    gas: int64                # gas provided by the sender.
    input: seq[byte]          # the data send along with the transaction.

server.on("eth_getTransactionByHash") do(data: Uint256) -> TransactionObject:
  ## Returns the information about a transaction requested by transaction hash.
  ##
  ## data: hash of a transaction.
  ## Returns requested transaction information.
  discard

server.on("eth_getTransactionByBlockHashAndIndex") do(data: UInt256, quantity: int) -> TransactionObject:
  ## Returns information about a transaction by block hash and transaction index position.
  ##
  ## data: hash of a block.
  ## quantity: integer of the transaction index position.
  ## Returns  requested transaction information.
  discard

server.on("eth_getTransactionByBlockNumberAndIndex") do(quantityTag: string, quantity: int) -> TransactionObject:
  ## Returns information about a transaction by block number and transaction index position.
  ##
  ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
  ## quantity: the transaction index position.
  discard

type
  ReceiptKind = enum rkRoot, rkStatus
  ReceiptObject = object
    # A transaction receipt object, or null when no receipt was found:
    transactionHash: UInt256          # hash of the transaction.
    transactionIndex: int             # integer of the transactions index position in the block.
    blockHash: UInt256                # hash of the block where this transaction was in.
    blockNumber: int                  # block number where this transaction was in.
    cumulativeGasUsed: int            # the total amount of gas used when this transaction was executed in the block.
    gasUsed: int                      # the amount of gas used by this specific transaction alone.
    contractAddress: array[20, byte]  # the contract address created, if the transaction was a contract creation, otherwise null.
    logs: seq[string]                 # TODO: See Wiki for details. list of log objects, which this transaction generated.
    logsBloom: array[256, byte]       # bloom filter for light clients to quickly retrieve related logs.
    case kind: ReceiptKind
    of rkRoot: root: UInt256          # post-transaction stateroot (pre Byzantium).
    of rkStatus: status: int          # 1 = success, 0 = failure.

server.on("eth_getTransactionReceipt") do(data: UInt256) -> ReceiptObject:
  ## Returns the receipt of a transaction by transaction hash.
  ##
  ## data: hash of a transaction.
  ## Returns transaction receipt.
  discard

server.on("eth_getUncleByBlockHashAndIndex") do(data: UInt256, quantity: int64) -> BlockObject:
  ## Returns information about a uncle of a block by hash and uncle index position.  
  ##
  ## data: hash a block.
  ## quantity: the uncle's index position.
  ## Returns BlockObject or nil when no block was found.
  discard

server.on("eth_getUncleByBlockNumberAndIndex") do(quantityTag: string, quantity: int64) -> BlockObject:
  # Returns information about a uncle of a block by number and uncle index position.
  ##
  ## quantityTag: a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
  ## quantity: the uncle's index position.
  ## Returns BlockObject or nil when no block was found.
  discard

server.on("eth_getCompilers") do() -> seq[string]:
  ## Returns a list of available compilers in the client.
  ##
  ## Returns a list of available compilers.
  result = @[]

server.on("eth_compileSolidity") do(sourceCode: string) -> seq[byte]:
  ## Returns compiled solidity code.
  ##
  ## sourceCode: source code as string.
  ## Returns compiles source code.
  result = @[]

server.on("eth_compileLLL") do(sourceCode: string) -> seq[byte]:
  ## Returns compiled LLL code.
  ##
  ## sourceCode: source code as string.
  ## Returns compiles source code.
  result = @[]

server.on("eth_compileSerpent") do(sourceCode: string) -> seq[byte]:
  ## Returns compiled serpent code.
  ##
  ## sourceCode: source code as string.
  ## Returns compiles source code.
  result = @[]

type
  FilterDataKind = enum fkItem, fkList
  FilterData = object
    # Difficult to process variant objects in input data, as kind is immutable.
    # TODO: This might need more work to handle "or" options
    kind: FilterDataKind
    items: seq[FilterData]
    item: UInt256
    # TODO: I don't think this will work as input, need only one value that is either UInt256 or seq[UInt256]

  FilterOptions = object
    fromBlock: string             # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    toBlock: string               # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    address: seq[array[20, byte]] # (optional) contract address or a list of addresses from which logs should originate.
    topics: seq[FilterData]       # (optional) list of DATA topics. Topics are order-dependent. Each topic can also be a list of DATA with "or" options.

server.on("eth_newFilter") do(filterOptions: FilterOptions) -> int:
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

server.on("eth_newBlockFilter") do() -> int:
  ## Creates a filter in the node, to notify when a new block arrives.
  ## To check if the state has changed, call eth_getFilterChanges.
  ##
  ## Returns integer filter id.
  discard

server.on("eth_newPendingTransactionFilter") do() -> int:
  ## Creates a filter in the node, to notify when a new block arrives.
  ## To check if the state has changed, call eth_getFilterChanges.
  ##
  ## Returns integer filter id.
  discard

server.on("eth_uninstallFilter") do(filterId: int) -> bool:
  ## Uninstalls a filter with given id. Should always be called when watch is no longer needed. 
  ## Additonally Filters timeout when they aren't requested with eth_getFilterChanges for a period of time.
  ##
  ## filterId: The filter id.
  ## Returns true if the filter was successfully uninstalled, otherwise false.
  discard

type
  LogObject = object
    removed: bool             # true when the log was removed, due to a chain reorganization. false if its a valid log.
    logIndex: int             # integer of the log index position in the block. null when its pending log.
    transactionIndex: ref int # integer of the transactions index position log was created from. null when its pending log.
    transactionHash: UInt256  # hash of the transactions this log was created from. null when its pending log.
    blockHash: ref UInt256    # hash of the block where this log was in. null when its pending. null when its pending log.
    blockNumber: ref int64    # the block number where this log was in. null when its pending. null when its pending log.
    address: array[20, byte]  # address from which this log originated.
    data: seq[UInt256]        # contains one or more 32 Bytes non-indexed arguments of the log.
    topics: array[4, UInt256] # array of 0 to 4 32 Bytes DATA of indexed log arguments.
                              # (In solidity: The first topic is the hash of the signature of the event.
                              # (e.g. Deposit(address,bytes32,uint256)), except you declared the event with the anonymous specifier.)

server.on("eth_getFilterChanges") do(filterId: int) -> seq[LogObject]:
  ## Polling method for a filter, which returns an list of logs which occurred since last poll.
  ##
  ## filterId: the filter id.
  result = @[]

server.on("eth_getFilterLogs") do(filterId: int) -> seq[LogObject]:
  ## filterId: the filter id.
  ## Returns a list of all logs matching filter with given id.
  result = @[]

server.on("eth_getLogs") do(filterOptions: FilterOptions) -> seq[LogObject]:
  ## filterOptions: settings for this filter.
  ## Returns a list of all logs matching a given filter object.
  result = @[]

server.on("eth_getWork") do() -> seq[UInt256]:
  ## Returns the hash of the current block, the seedHash, and the boundary condition to be met ("target").
  ## Returned list has the following properties:
  ## DATA, 32 Bytes - current block header pow-hash.
  ## DATA, 32 Bytes - the seed hash used for the DAG.
  ## DATA, 32 Bytes - the boundary condition ("target"), 2^256 / difficulty.
  result = @[]

server.on("eth_submitWork") do(nonce: int64, powHash: Uint256, mixDigest: Uint256) -> bool:
  ## Used for submitting a proof-of-work solution.
  ##
  ## nonce: the nonce found.
  ## headerPow: the header's pow-hash.
  ## mixDigest: the mix digest.
  ## Returns true if the provided solution is valid, otherwise false.
  discard

server.on("eth_submitHashrate") do(hashRate: UInt256, id: Uint256) -> bool:
  ## Used for submitting mining hashrate.
  ##
  ## hashRate: a hexadecimal string representation (32 bytes) of the hash rate.
  ## id: a random hexadecimal(32 bytes) ID identifying the client.
  ## Returns true if submitting went through succesfully and false otherwise.
  discard

server.on("shh_version") do() -> string:
  ## Returns string of the current whisper protocol version.
  discard

type
  WhisperPost = object
    # The whisper post object:
    source: array[60, byte] # (optional) the identity of the sender.
    to: array[60, byte]     # (optional) the identity of the receiver. When present whisper will encrypt the message so that only the receiver can decrypt it.
    topics: seq[UInt256]    # TODO: Correct type? list of DATA topics, for the receiver to identify messages.
    payload: UInt256        # TODO: Correct type - maybe string? the payload of the message.
    priority: int           # integer of the priority in a rang from ... (?).
    ttl: int                # integer of the time to live in seconds.

server.on("shh_post") do(message: WhisperPost) -> bool:
  ## Sends a whisper message.
  ##
  ## message: Whisper message to post.
  ## Returns true if the message was send, otherwise false.
  discard

server.on("shh_newIdentity") do() -> array[60, byte]:
  ## Creates new whisper identity in the client.
  ##
  ## Returns the address of the new identiy.
  discard

server.on("shh_hasIdentity") do(identity: array[60, byte]) -> bool:
  ## Checks if the client holds the private keys for a given identity.
  ##
  ## identity: the identity address to check.
  ## Returns true if the client holds the privatekey for that identity, otherwise false.
  discard

server.on("shh_newGroup") do() -> array[60, byte]:
  ## (?) - This has no description information in the RPC wiki.
  ##
  ## Returns the address of the new group. (?)
  discard

server.on("shh_addToGroup") do(identity: array[60, byte]) -> bool:
  ## (?) - This has no description information in the RPC wiki.
  ##
  ## identity: the identity address to add to a group (?).
  ## Returns true if the identity was successfully added to the group, otherwise false (?).
  discard

server.on("shh_newFilter") do(filterOptions: FilterOptions, to: array[60, byte], topics: seq[UInt256]) -> int: # TODO: Is topic of right type?
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

server.on("shh_uninstallFilter") do(id: int) -> bool:
  ## Uninstalls a filter with given id.
  ## Should always be called when watch is no longer needed.
  ## Additonally Filters timeout when they aren't requested with shh_getFilterChanges for a period of time.
  ##
  ## id: the filter id.
  ## Returns true if the filter was successfully uninstalled, otherwise false.
  discard

type
  WhisperMessage = object
    # (?) are from the RPC Wiki, indicating uncertainty in type format.
    hash: UInt256           # (?) the hash of the message.
    source: array[60, byte] # the sender of the message, if a sender was specified.
    to: array[60, byte]     # the receiver of the message, if a receiver was specified.
    expiry: int             # integer of the time in seconds when this message should expire (?).
    ttl: int                # integer of the time the message should float in the system in seconds (?).
    sent: int               # integer of the unix timestamp when the message was sent.
    topics: seq[UInt256]    # list of DATA topics the message contained.
    payload: string         # TODO: Correct type? the payload of the message.
    workProved: int         # integer of the work this message required before it was send (?).

server.on("shh_getFilterChanges") do(id: int) -> seq[WhisperMessage]:
  ## Polling method for whisper filters. Returns new messages since the last call of this method.
  ## Note: calling the shh_getMessages method, will reset the buffer for this method, so that you won't receive duplicate messages.
  ##
  ## id: the filter id.
  discard

server.on("shh_getMessages") do(id: int) -> seq[WhisperMessage]:
  ## Get all messages matching a filter. Unlike shh_getFilterChanges this returns all messages.
  ##
  ## id: the filter id.
  ## Returns a list of messages received since last poll.
  discard

