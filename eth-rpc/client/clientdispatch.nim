import asyncnet, asyncdispatch, tables, json, oids, ethcalls, macros
import ../ ethtypes, stint, ../ jsonconverters

type
  RpcClient* = ref object
    socket: AsyncSocket
    awaiting: Table[string, Future[Response]]
    address: string
    port: Port
    nextId: int64
  Response* = tuple[error: bool, result: JsonNode]


proc newRpcClient*(): RpcClient =
  ## Creates a new ``RpcClient`` instance. 
  RpcClient(
    socket: newAsyncSocket(),
    awaiting: initTable[string, Future[Response]](),
    nextId: 1
  )

proc call*(self: RpcClient, name: string, params: JsonNode): Future[Response] {.async.} =
  ## Remotely calls the specified RPC method.
  let id = $self.nextId
  self.nextId.inc
  let msg = $ %{"jsonrpc": %"2.0", "method": %name, "params": params, "id": %id} & "\c\l"
  await self.socket.send(msg)

  # completed by processMessage.
  var newFut = newFuture[Response]()
  # add to awaiting responses
  self.awaiting[id] = newFut
  result = await newFut

macro checkGet(node: JsonNode, fieldName: string, jKind: static[JsonNodeKind]): untyped =
  result = quote do:
    let n = `node`{`fieldName`}
    if n.isNil: raise newException(ValueError, "Message is missing required field \"" & `fieldName` & "\"")
    if n.kind != `jKind`.JsonNodeKind: raise newException(ValueError, "Expected " & $(`jKind`.JsonNodeKind) & ", got " & $`node`[`fieldName`].kind)
  case jKind
  of JBool: result.add(quote do: `node`[`fieldName`].getBool)
  of JInt: result.add(quote do: `node`[`fieldName`].getInt)
  of JString: result.add(quote do: `node`[`fieldName`].getStr)
  of JFloat: result.add(quote do: `node`[`fieldName`].getFloat)
  of JObject: result.add(quote do: `node`[`fieldName`].getObject)
  else: discard

proc processMessage(self: RpcClient, line: string) =
  let node = parseJson(line)
  
  # TODO: Use more appropriate exception objects
  let version = checkGet(node, "jsonrpc", JString)
  if version != "2.0": raise newException(ValueError, "Unsupported version of JSON, expected 2.0, received \"" & version & "\"")

  let id = checkGet(node, "id", JString)
  if not self.awaiting.hasKey(id): raise newException(ValueError, "Cannot find message id \"" & node["id"].str & "\"")

  let errorNode = node{"error"}
  if errorNode.isNil or errorNode.kind == JNull:
    var res = node{"result"}
    if not res.isNil:
      self.awaiting[id].complete((false, res))
    self.awaiting.del(id)
    # TODO: actions on unable find result node
  else:
    self.awaiting[id].complete((true, errorNode))
    self.awaiting.del(id)

proc connect*(self: RpcClient, address: string, port: Port): Future[void]

proc processData(self: RpcClient) {.async.} =
  while true:
    # read until no data
    let line = await self.socket.recvLine()

    if line == "":
      # transmission ends
      self.socket.close()  # TODO: Do we need to drop/reacquire sockets?
      self.socket = newAsyncSocket()
      break
    
    processMessage(self, line)
  # async loop reconnection and waiting
  await connect(self, self.address, self.port)

proc connect*(self: RpcClient, address: string, port: Port) {.async.} =
  await self.socket.connect(address, port)
  self.address = address
  self.port = port
  asyncCheck processData(self)

import jsonmarshal

proc createRpcProc(procName, parameters, callBody: NimNode): NimNode =
  # parameters come as a tree
  var paramList = newSeq[NimNode]()
  for p in parameters: paramList.add(p)

  result = newProc(procName, paramList, callBody)           # build proc
  result.addPragma ident"async"                             # make proc async               
  result[0] = nnkPostFix.newTree(ident"*", newIdentNode($procName))  # export this proc

proc toJsonNode(parameters: NimNode): NimNode =
  # outputs an array of jsonified parameters
  # ie; %[%a, %b, %c]
  parameters.expectKind nnkFormalParams
  var items = newNimNode(nnkBracket)
  for i in 2 ..< parameters.len:
    let curParam = parameters[i][0]
    if curParam.kind != nnkEmpty:
      items.add(nnkPrefix.newTree(ident"%", curParam))
  result = nnkPrefix.newTree(newIdentNode("%"), items)

proc createRpcFromSig*(rpcDecl: NimNode): NimNode =
  var
    parameters = rpcDecl.findChild(it.kind == nnkFormalParams).copy
    procName = rpcDecl.name
    pathStr = $procName   

  # ensure we have at least space for a return parameter  
  if parameters.isNil or parameters.kind == nnkEmpty or parameters.len == 0:
    parameters = nnkFormalParams.newTree(newEmptyNode())

  # insert rpc client as first parameter
  parameters.insert(1, 
    nnkIdentDefs.newTree(
      ident"client",
      ident"RpcClient",
      newEmptyNode()
    )
  )

  # For each input parameter we need to
  # take the Nim type and translate to json with `%`.
  # For return types, we need to take the json and
  # convert it to the Nim type.
  let
    jsonParamIdent = genSym(nskVar, "jsonParam")
    jsonArrayInit = parameters.toJsonNode()
  var
    returnType: NimNode
    callBody = newStmtList().add(quote do:
      var `jsonParamIdent` = `jsonArrayInit`
    )

  if parameters[0].kind != nnkEmpty:
    returnType = parameters[0]
  else:
    returnType = ident"JsonNode"
  
  # convert return type to Future
  parameters[0] = nnkBracketExpr.newTree(ident"Future", returnType)

  result = createRpcProc(procName, parameters, callBody)
  var callResult = genSym(nskVar, "res")

  # create client call to server using json params
  callBody.add(quote do:
    let res = await client.call(`pathStr`, `jsonParamIdent`)
    if res.error: raise newException(ValueError, $res.result)
    var `callResult` = res.result
  )
  let
    procRes = ident"result"
  # now we need to extract the response and build it into the expected type
  if returnType != ident"JsonNode":
    let setup = setupParamFromJson(procRes, returnType, callResult)
    callBody.add(quote do: `setup`)
  else:
    callBody.add(quote do:
      `procRes` = `callResult`
      )
  when defined(nimDumpRpcs):
    echo pathStr, ":\n", result.repr

from os import getCurrentDir, DirSep
from strutils import rsplit

macro processRpcSigs(): untyped =
  result = newStmtList()
  const
    codePath = currentSourcePath.rsplit(DirSep, 1)[0] & DirSep & "ethcallsigs.nim"
    code = staticRead(codePath)

  let parsedCode = parseStmt(code)
  for line in parsedCode:
    if line.kind == nnkProcDef:
      var procDef = createRpcFromSig(line)
      result.add(procDef)

# generate all client ethereum rpc calls
processRpcSigs()
