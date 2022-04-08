import stint

type
  SyncObject* = object
    startingBlock*: int
    currentBlock*: int
    highestBlock*: int

  EthSend* = object
    source*: array[20, byte]  # the address the transaction is send from.
    to*: array[20, byte]      # (optional when creating new contract) the address the transaction is directed to.
    gas*: int                 # (optional, default: 90000) integer of the gas provided for the transaction execution. It will return unused gas.
    gasPrice*: int            # (optional, default: To-Be-Determined) integer of the gasPrice used for each paid gas.
    value*: int               # (optional) integer of the value sent with this transaction.
    data*: int                # the compiled code of a contract OR the hash of the invoked method signature and encoded parameters. For details see Ethereum Contract ABI.
    nonce*: int               # (optional) integer of a nonce. This allows to overwrite your own pending transactions that use the same nonce

  EthCall* = object
    source*: array[20, byte]  # (optional) The address the transaction is send from.
    to*: array[20, byte]      # The address the transaction is directed to.
    gas*: int                 # (optional) Integer of the gas provided for the transaction execution. eth_call consumes zero gas, but this parameter may be needed by some executions.
    gasPrice*: int            # (optional) Integer of the gasPrice used for each paid gas.
    value*: int               # (optional) Integer of the value sent with this transaction.
    data*: int                # (optional) Hash of the method signature and encoded parameters. For details see Ethereum Contract ABI.

  ## A block object, or null when no block was found
  BlockObject* = ref object
    number*: int                  # the block number. null when its pending block.
    hash*: UInt256                # hash of the block. null when its pending block.
    parentHash*: UInt256          # hash of the parent block.
    nonce*: int64                 # hash of the generated proof-of-work. null when its pending block.
    sha3Uncles*: UInt256          # SHA3 of the uncles data in the block.
    logsBloom*: array[256, byte]  # the bloom filter for the logs of the block. null when its pending block.
    transactionsRoot*: UInt256    # the root of the transaction trie of the block.
    stateRoot*: UInt256           # the root of the final state trie of the block.
    receiptsRoot*: UInt256        # the root of the receipts trie of the block.
    miner*: array[20, byte]       # the address of the beneficiary to whom the mining rewards were given.
    difficulty*: int              # integer of the difficulty for this block.
    totalDifficulty*: int         # integer of the total difficulty of the chain until this block.
    extraData*: string            # the "extra data" field of this block.
    size*: int                    # integer the size of this block in bytes.
    gasLimit*: int                # the maximum gas allowed in this block.
    gasUsed*: int                 # the total used gas by all transactions in this block.
    timestamp*: int               # the unix timestamp for when the block was collated.
    transactions*: seq[UInt256]   # list of transaction objects, or 32 Bytes transaction hashes depending on the last given parameter.
    uncles*: seq[UInt256]         # list of uncle hashes.

  TransactionObject* = object     # A transaction object, or null when no transaction was found:
    hash*: UInt256                # hash of the transaction.
    nonce*: int64                 # TODO: Is int? the number of transactions made by the sender prior to this one.
    blockHash*: UInt256           # hash of the block where this transaction was in. null when its pending.
    blockNumber*: int64           # block number where this transaction was in. null when its pending.
    transactionIndex*: int64      # integer of the transactions index position in the block. null when its pending.
    source*: array[20, byte]      # address of the sender.
    to*: array[20, byte]          # address of the receiver. null when its a contract creation transaction.
    value*: int64                 # value transferred in Wei.
    gasPrice*: int64              # gas price provided by the sender in Wei.
    gas*: int64                   # gas provided by the sender.
    input*: seq[byte]             # the data send along with the transaction.

  ReceiptKind* = enum rkRoot, rkStatus
  ReceiptObject* = object
    # A transaction receipt object, or null when no receipt was found:
    transactionHash*: UInt256         # hash of the transaction.
    transactionIndex*: int            # integer of the transactions index position in the block.
    blockHash*: UInt256               # hash of the block where this transaction was in.
    blockNumber*: int                 # block number where this transaction was in.
    cumulativeGasUsed*: int           # the total amount of gas used when this transaction was executed in the block.
    gasUsed*: int                     # the amount of gas used by this specific transaction alone.
    contractAddress*: array[20, byte] # the contract address created, if the transaction was a contract creation, otherwise null.
    logs*: seq[string]                # TODO: See Wiki for details. list of log objects, which this transaction generated.
    logsBloom*: array[256, byte]      # bloom filter for light clients to quickly retrieve related logs.
    # TODO:
    #case kind*: ReceiptKind
    #of rkRoot: root*: UInt256         # post-transaction stateroot (pre Byzantium).
    #of rkStatus: status*: int         # 1 = success, 0 = failure.

  FilterDataKind* = enum fkItem, fkList
  FilterData* = object
    # Difficult to process variant objects in input data, as kind is immutable.
    # TODO: This might need more work to handle "or" options
    kind*: FilterDataKind
    items*: seq[FilterData]
    item*: UInt256
    # TODO: I don't think this will work as input, need only one value that is either UInt256 or seq[UInt256]

  FilterOptions* = object
    fromBlock*: string              # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    toBlock*: string                # (optional, default: "latest") integer block number, or "latest" for the last mined block or "pending", "earliest" for not yet mined transactions.
    address*: seq[array[20, byte]]  # (optional) contract address or a list of addresses from which logs should originate.
    topics*: seq[FilterData]        # (optional) list of DATA topics. Topics are order-dependent. Each topic can also be a list of DATA with "or" options.

  LogObject* = object
    removed*: bool              # true when the log was removed, due to a chain reorganization. false if its a valid log.
    logIndex*: int              # integer of the log index position in the block. null when its pending log.
    transactionIndex*: ref int  # integer of the transactions index position log was created from. null when its pending log.
    transactionHash*: UInt256   # hash of the transactions this log was created from. null when its pending log.
    blockHash*: ref UInt256     # hash of the block where this log was in. null when its pending. null when its pending log.
    blockNumber*: ref int64     # the block number where this log was in. null when its pending. null when its pending log.
    address*: array[20, byte]   # address from which this log originated.
    data*: seq[UInt256]         # contains one or more 32 Bytes non-indexed arguments of the log.
    topics*: array[4, UInt256]  # array of 0 to 4 32 Bytes DATA of indexed log arguments.
                                # (In solidity: The first topic is the hash of the signature of the event.
                                # (e.g. Deposit(address,bytes32,uint256)), except you declared the event with the anonymous specifier.)

  WhisperPost* = object
    # The whisper post object:
    source*: array[60, byte]    # (optional) the identity of the sender.
    to*: array[60, byte]        # (optional) the identity of the receiver. When present whisper will encrypt the message so that only the receiver can decrypt it.
    topics*: seq[UInt256]       # TODO: Correct type? list of DATA topics, for the receiver to identify messages.
    payload*: UInt256           # TODO: Correct type - maybe string? the payload of the message.
    priority*: int              # integer of the priority in a rang from ... (?).
    ttl*: int                   # integer of the time to live in seconds.

  WhisperMessage* = object
    # (?) are from the RPC Wiki, indicating uncertainty in type format.
    hash*: UInt256              # (?) the hash of the message.
    source*: array[60, byte]    # the sender of the message, if a sender was specified.
    to*: array[60, byte]        # the receiver of the message, if a receiver was specified.
    expiry*: int                # integer of the time in seconds when this message should expire (?).
    ttl*: int                   # integer of the time the message should float in the system in seconds (?).
    sent*: int                  # integer of the unix timestamp when the message was sent.
    topics*: seq[UInt256]       # list of DATA topics the message contained.
    payload*: string            # TODO: Correct type? the payload of the message.
    workProved*: int            # integer of the work this message required before it was send (?).