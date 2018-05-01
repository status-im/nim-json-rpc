import asyncdispatch, asyncnet, json, tables, macros, strutils
export asyncdispatch, asyncnet, json

type
  RpcProc* = proc (params: JsonNode): Future[JsonNode]

  RpcServer* = ref object
    socket*: AsyncSocket
    port*: Port
    address*: string
    procs*: TableRef[string, RpcProc]

  RpcProcError* = ref object of Exception
    code*: int
    data*: JsonNode

proc register*(server: RpcServer, name: string, rpc: RpcProc) =
  server.procs[name] = rpc

proc unRegisterAll*(server: RpcServer) = server.procs.clear

macro rpc*(prc: untyped): untyped =
  ## Converts a procedure into the following format:
  ##  <proc name>*(params: JsonNode): Future[JsonNode] {.async.}
  ## This procedure is then added into a compile-time list
  ## so that it is automatically registered for every server that
  ## calls registerRpcs(server)
  prc.expectKind nnkProcDef
  result = prc
  let
    params = prc.params
    procName = prc.name

  procName.expectKind(nnkIdent)
  
  # check there isn't already a result type
  assert params[0].kind == nnkEmpty

  # add parameter
  params.add nnkIdentDefs.newTree(
        newIdentNode("params"),
        newIdentNode("JsonNode"),
        newEmptyNode()
      )
  # set result type
  params[0] = nnkBracketExpr.newTree(
    newIdentNode("Future"),
    newIdentNode("JsonNode")
  )
  # add async pragma; we can assume there isn't an existing .async.
  # as this would mean there's a return type and fail the result check above.
  prc.addPragma(newIdentNode("async"))

proc newRpcServer*(address = "localhost", port: Port = Port(8545)): RpcServer =
  result = RpcServer(
    socket: newAsyncSocket(),
    port: port,
    address: address,
    procs: newTable[string, RpcProc]()
  )

var sharedServer: RpcServer

proc sharedRpcServer*(): RpcServer =
  if sharedServer.isNil: sharedServer = newRpcServer("")
  result = sharedServer

macro multiRemove(s: string, values: varargs[string]): untyped =
  ## Wrapper for multiReplace
  var
    body = newStmtList()
    multiReplaceCall = newCall(ident"multiReplace", s)

  body.add(newVarStmt(ident"eStr", newStrLitNode("")))
  let emptyStr = ident"eStr"
  for item in values:
    # generate tuples of values with the empty string `eStr`
    let sItem = $item
    multiReplaceCall.add(newPar(newStrLitNode(sItem), emptyStr))

  body.add multiReplaceCall
  result = newBlockStmt(body)

proc jsonGetFunc(paramType: string): NimNode =
  case paramType
  of "string": result = ident"getStr"
  of "int": result = ident"getInt"
  of "float": result = ident"getFloat"
  of "bool": result = ident"getBool"
  of "byte": result = ident"getInt"
  else: result = nil

proc jsonCheckType(paramType: string): NimNode =
  case paramType
  of "string": result = ident"JString"
  of "int": result = ident"JInt"
  of "float": result = ident"JFloat"
  of "bool": result = ident"JBool"
  of "byte": result = ident"JInt"
  else: result = nil

proc preParseTypes(typeNode: var NimNode, typeName: NimNode, errorCheck: var NimNode): bool {.compileTime.} =
  # handle byte
  for i, item in typeNode:
    if item.kind == nnkIdent and item.basename == ident"byte":
      typeNode[i] = ident"int"
      # add some extra checks
      result = true
    else:
      var t = typeNode[i]
      if preParseTypes(t, typeName, errorCheck):
        typeNode[i] = t

proc expect(node, jsonIdent, fieldName: NimNode, tn: JsonNodeKind) =
  let
    expectedStr = "Expected parameter `" & fieldName.repr & "` to be " & $tn & " but got "
    tnIdent = ident($tn)
  node.add(quote do:
    if `jsonIdent`.kind != `tnIdent`:
      raise newException(ValueError, `expectedStr` & $`jsonIdent`.kind)
  )
  
macro processFields(jsonIdent, fieldName, fieldType: typed): untyped =
  result = newStmtList()
  let typeInfo = getType(getType(fieldType))
  typeInfo.expectKind nnkBracketExpr
  let typeDesc = getType(typeInfo[1])
  case typeDesc.kind
  of nnkObjectTy:
    let
      recs = typeDesc.findChild it.kind == nnkRecList
    assert recs != nil, "Detected object type but no RecList found to traverse fields"
    result.expect(jsonIdent, fieldName, JObject)
    for i in 0 ..< recs.len:
      var
        objFieldName = recs[i]
        fns = objFieldName.toStrLit
        objFieldType = getType(recs[i])
      var fieldRealType = nnkBracketExpr.newTree(typeInfo[0], objFieldType)
      result.add(quote do:
        processFields(`jsonIdent`[`fns`], `fieldName`.`objfieldName`, `fieldRealType`)
        )
  of nnkBracketExpr:
    let
      brType = typeInfo[1][1]
      brFormat = $typeInfo[1][0] # seq/array
    var typeName: NimNode
    
    if brType.kind == nnkBracketExpr: typeName = typeInfo[1][2]
    else: typeName = brType
    result.expect(jsonIdent, fieldName, JArray)

    let jFunc = jsonGetFunc($typeName)
    if brFormat == "seq":
      result.add(quote do:
        `fieldName` = @[]
        `fieldName`.setLen(`jsonIdent`.len)
      )
    else:
      # array
      let
        startLen = typeInfo[1][1][1]
        endLen = typeInfo[1][1][2] 
        expectedLen = genSym(nskConst)
        expectedParams = quote do:
          const `expectedLen` = `endLen` - `startLen` + 1
        expectedLenStr = "Expected parameter `" & fieldName.repr & "` to have a length of "
      # TODO: Note, currently only raising if greater than value, not different size
      result.add(quote do:
        `expectedParams`
        if `jsonIdent`.len > `expectedLen`:
          raise newException(ValueError, `expectedLenStr` & $`expectedLen` & " but got " & $`jsonIdent`.len)
      )
        
    result.add(quote do:
      for i in 0 ..< `jsonIdent`.len: 
        `fieldName`[i] = `jsonIdent`.elems[i].`jFunc`
    )
  of nnkSym:
    let
      typeName = $typeDesc
      jFetch = jsonGetFunc(typeName)
    result.add(quote do:
      `fieldName` = `jsonIdent`.`jFetch`
    )
  else: echo "Unhandled type: ", typeDesc.kind
  echo result.repr

proc setupParams(node, parameters, paramsIdent: NimNode) =
  # recurse parameter's fields until we only have symbols
  if not parameters.isNil:
    var
      errorCheck = newStmtList()
      expectedParams = parameters.len - 1
    let expectedStr = "Expected " & $`expectedParams` & " Json parameter(s) but got "
    node.add(quote do:
      if `paramsIdent`.len != `expectedParams`:
        raise newException(ValueError, `expectedStr` & $`paramsIdent`.len)
    )

    for i in 1..< parameters.len:
      let
        paramName = parameters[i][0]
        pos = i - 1
      var
        paramType = parameters[i][1]
      discard paramType.preParseTypes(paramName, errorCheck)
      node.add(quote do:
        var `paramName`: `paramType`
        processFields(`paramsIdent`[`pos`], `paramName`, `paramType`)
        `errorCheck`
      )
      # TODO: Check for byte ranges

macro on*(server: var RpcServer, path: string, body: untyped): untyped =
  result = newStmtList()
  var setup = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    paramsIdent = ident"params"  
  setup.setupParams(parameters, paramsIdent)

  # wrapping proc
  let
    pathStr = $path
    procName = ident(pathStr.multiRemove(".", "/")) # TODO: Make this unique to avoid potential clashes, or allow people to know the name for calling?
  var procBody: NimNode
  if body.kind == nnkStmtList: procBody = body
  else: procBody = body.body
  result = quote do:
    proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
      #`checkTypeError`
      `setup`
      `procBody`
    `server`.register(`path`, `procName`)
  when defined(nimDumpRpcs):
    echo pathStr, ": ", result.repr

when isMainModule:
  import unittest
  var s = newRpcServer("localhost")
  s.on("rpc.simplepath"):
    echo "hello3"
    result = %1
  s.on("rpc.returnint") do() -> int:
    echo "hello2"
  s.on("rpc.differentparams") do(a: int, b: string):
    var node = %"test"
    result = node
  s.on("rpc.arrayparam") do(arr: array[0..5, byte], b: string):
    var res = newJArray()
    for item in arr:
      res.add %int(item)
    res.add %b
    result = %res
    echo result
  s.on("rpc.seqparam") do(a: string, s: seq[int]):
    var res = newJArray()
    res.add %a
    for item in s:
      res.add %int(item)
    result = res
  type Test = object
    a: seq[int] #array[0..10, int]

  type MyObject* = object
    a: int
    b: Test
    c: float
  s.on("rpc.objparam") do(a: string, obj: MyObject):
    result = %obj
  suite "Server types":
    test "On macro registration":
      check s.procs.hasKey("rpc.simplepath")
      check s.procs.hasKey("rpc.returnint")
      check s.procs.hasKey("rpc.returnint")
    test "Array/seq parameters":
      let r1 = waitfor rpcArrayParam(%[%[1, 2, 3], %"hello"])
      var ckR1 = %[1, 2, 3, 0, 0, 0]
      ckR1.elems.add %"hello"
      check r1 == ckR1

      let r2 = waitfor rpcSeqParam(%[%"abc", %[1, 2, 3, 4, 5]])
      var ckR2 = %["abc"]
      for i in 0..4: ckR2.add %(i + 1)
      check r2 == ckR2
    test "Object parameters":
      let
        obj = %*{"a": %1, "b": %*{"a": %[5]}, "c": %1.23}
        r = waitfor rpcObjParam(%[%"abc", obj])
      check r == obj
    test "Runtime errors":
      expect ValueError:
        echo waitfor rpcArrayParam(%[%[0, 1, 2, 3, 4, 5, 6], %"hello"])


