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

macro on*(server: var RpcServer, path: string, body: untyped): untyped =
  var
    paramTemplates = newStmtList()
    expectedParams = 0
  let parameters = body.findChild(it.kind == nnkFormalParams)
  if not parameters.isNil:
    # process parameters of body into json fetch templates
    var resType = parameters[0]
    if resType.kind != nnkEmpty:
      # TODO: transform result type and/or return to json
      discard

    var paramsIdent = ident"params"
    expectedParams = parameters.len - 1

    for i in 1..<parameters.len:
      let pos = i - 1 # first index is return type
      parameters[i].expectKind nnkIdentDefs

      # take user's parameter name for template
      let name = parameters[i][0] 
      var paramType = parameters[i][1]
      paramTemplates.add(quote do:
        if `paramsIdent`.len != `expectedParams`:
          raise newException(ValueError, "Expected " & $`expectedParams` & " Json parameters but got " & $`paramsIdent`.len)
      )
      
      # TODO: marshalling for object types
      # TODO: Replace exception with async error return values
      # Requires passing the server in local parameters to access the socket

      if paramType.kind == nnkBracketExpr:
        # process array and seq parameters
        # and marshall json arrays to requested types
        let paramTypeStr = $paramType[0]
        assert paramTypeStr == "array" or paramTypeStr == "seq"
        
        let idx = ident"i"
        
        if paramTypeStr == "array":
          paramType.expectLen 3
          let arrayLen = paramType[1]
          let arrayType = paramType[2]
          let getFunc = jsonGetFunc($arrayType)

          paramTemplates.add(quote do:
            if `paramsIdent`.elems[`pos`].kind != JArray:
              raise newException(ValueError, "Expected array but got " & $`paramsIdent`.elems[`pos`].kind)
            var `name`: `paramType`
            if `paramsIdent`.len > `name`.len:
              raise newException(ValueError, "Array longer than parameter allows. Expected " & $`arrayLen` & ", data length is " & $`paramsIdent`.elems[`pos`].len)
            else:
              for `idx` in 0 ..< `paramsIdent`.elems[`pos`].len:
                `name`[`idx`] = `arrayType`(`paramsIdent`.elems[`pos`].elems[`idx`].`getFunc`)
          )        
        else:
          paramType.expectLen 2
          let
            seqType = paramType[1]
            getFunc = jsonGetFunc($seqType)
          paramTemplates.add(quote do:
            if `paramsIdent`.elems[`pos`].kind != JArray:
              raise newException(ValueError, "Expected array but got " & $`paramsIdent`.elems[`pos`].kind)
            var `name` = newSeq[`seqType`](`paramsIdent`.elems[`pos`].len)
            for `idx` in 0 ..< `paramsIdent`.elems[`pos`].len:
              `name`[`idx`] = `seqType`(`paramsIdent`.elems[`pos`].elems[`idx`].`getFunc`)
          )
      else:
        # other types
        var getFuncName = jsonGetFunc($paramType)
        assert getFuncName != nil
        # fetch parameter 
        let getFunc = newIdentNode($getFuncName)
        paramTemplates.add(quote do:
          var `name`: `paramType` = `paramsIdent`.elems[`pos`].`getFunc`
        )
  # create RPC proc
  let
    pathStr = $path
    procName = ident(pathStr.multiRemove(".", "/")) # TODO: Make this unique to avoid potential clashes, or allow people to know the name for calling?
    paramsIdent = ident("params")
  var procBody: NimNode
  if body.kind == nnkStmtList: procBody = body
  else: procBody = body.body
  #
  var checkTypeError: NimNode
  if expectedParams > 0:
    checkTypeError = quote do:
      if `paramsIdent`.kind != JArray:
        raise newException(ValueError, "Expected array but got " & $`paramsIdent`.kind)
  else: checkTypeError = newStmtList()

  result = quote do:
    proc `procName`*(`paramsIdent`: JsonNode): Future[JsonNode] {.async.} =
      `checkTypeError`
      `paramTemplates`
      `procBody`
    `server`.register(`path`, `procName`)
  echo result.repr

when isMainModule:
  import unittest
  var s = newRpcServer("localhost")
  s.on("the/path1"):
    echo "hello3"
    result = %1
  s.on("the/path2") do() -> int:
    echo "hello2"
  s.on("the/path3") do(a: int, b: string):
    var node = %"test"
    result = node
  s.on("the/path4") do(arr: array[6, byte], b: string):
    var res = newJArray()
    for item in arr:
      res.add %int(item)
    res.add %b
    result = %res
  s.on("the/path5") do(b: string, arr: seq[int]):
    var res = newJArray()
    res.add %b
    for item in arr:
      res.add %int(item)
    result = res
  suite "Server types":
    test "On macro registration":
      check s.procs.hasKey("the/path1")
      check s.procs.hasKey("the/path2")
      check s.procs.hasKey("the/path3")
    test "Array/seq parameters":
      let r1 = waitfor thepath4(%[%[1, 2, 3], %"hello"])
      var ckR1 = %[1, 2, 3, 0, 0, 0]
      ckR1.elems.add %"hello"
      check r1 == ckR1

      let r2 = waitfor thepath5(%[%"abc", %[1, 2, 3, 4, 5]])
      var ckR2 = %["abc"]
      for i in 0..4: ckR2.add %(i + 1)
      check r2 == ckR2
    