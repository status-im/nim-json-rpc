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

proc createRpcFromSig*(rpcDecl: NimNode): NimNode =
  let procNameState = rpcDecl[0]
  var
    parameters = rpcDecl.findChild(it.kind == nnkFormalParams).copy
    path: NimNode
    pathStr: string

  # get proc signature's name. This becomes the path we send to the server
  if procNameState.kind == nnkPostFix:
    path = rpcDecl[0][1]
  else:
    path = rpcDecl[0]
  pathStr = $path   

  if parameters.isNil or parameters.kind == nnkEmpty:
    parameters = newNimNode(nnkFormalParams)

  # if no return parameters specified (parameters[0])
  if parameters.len == 0: parameters.add(newEmptyNode())
  # insert rpc client as first parameter
  let
    clientParam =
      nnkIdentDefs.newTree(
        ident"client",
        ident"RpcClient",
        newEmptyNode()
      )
  parameters.insert(1, clientParam)

  # For each input parameter we need to
  # take the Nim type and translate to json with `%`.
  # For return types, we need to take the json and
  # convert it to the Nim type.
  var
    callBody = newStmtList()
    returnType: NimNode
  let jsonParamIdent = genSym(nskVar, "jsonParam")
  callBody.add(quote do:
    var `jsonParamIdent` = newJArray()
  )
  if parameters.len > 2:
    # skip return type and the inserted rpc client parameter
    # add the rest to json node via `%`
    for i in 2 ..< parameters.len:
      let curParam = parameters[i][0]
      if curParam.kind != nnkEmpty:
        callBody.add(quote do:
          `jsonParamIdent`.add(%`curParam`)
        )
  if parameters[0].kind != nnkEmpty:
    returnType = parameters[0]
  else:
    returnType = ident"JsonNode"
  
  # convert return type to Future
  parameters[0] = nnkBracketExpr.newTree(ident"Future", returnType)

  # client call to server using json params
  var updatedParams = newSeq[NimNode]()
  # convert parameter tree to seq
  for p in parameters: updatedParams.add(p) 
  # create new proc
  result = newProc(path, updatedParams, callBody)
  # convert this proc to async
  result.addPragma ident"async"
  # export this proc
  result[0] = nnkPostFix.newTree(ident"*", ident(pathStr))
  # add rpc call to proc body
  var callResult = genSym(nskVar, "res")

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
  var line = 0
  while line < parsedCode.len:
    if parsedCode[line].kind == nnkProcDef: break
    line += 1
  for curLine in line ..< parsedCode.len:
    var procDef = createRpcFromSig(parsedCode[curLine])
    result.add(procDef)

# generate all client ethereum rpc calls
processRpcSigs()
