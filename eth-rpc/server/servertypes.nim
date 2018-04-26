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

# TODO: Nested complex fields in objects
# Probably going to need to make it recursive

macro bindObj*(objInst: untyped, objType: typedesc, paramsArg: typed, elemIdx: int): untyped  =
  result = newNimNode(nnkStmtList)
  let typeDesc = getType(getType(objType)[1])
  for field in typeDesc[2].children:
    let
      fieldStr = $field
      fieldTypeStr = $field.getType()
      getFunc = jsonGetFunc(fieldTypeStr)
      expectedKind = fieldTypeStr.jsonCheckType
      expectedStr = "Expected " & $expectedKind & " but got "
    result.add(quote do:
      let jParam = `paramsArg`.elems[`elemIdx`][`fieldStr`]
      if jParam.kind != `expectedKind`:
        raise newException(ValueError, `expectedStr` & $jParam.kind)
      `objInst`.`field` = jParam.`getFunc`
    )
  when defined(nimDumpRpcs):
    echo "BindObj expansion: ", result.repr

macro on*(server: var RpcServer, path: string, body: untyped): untyped =
  var
    paramFetch = newStmtList()
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
    let expectedStr = "Expected " & $`expectedParams` & " Json parameter(s) but got "
    paramFetch.add(quote do:
      if `paramsIdent`.len != `expectedParams`:
        raise newException(ValueError, `expectedStr` & $`paramsIdent`.len)
    )

    for i in 1..<parameters.len:
      let pos = i - 1 # first index is return type
      parameters[i].expectKind nnkIdentDefs

      # take user's parameter name for template
      let name = parameters[i][0] 
      var paramType = parameters[i][1]
      
      # TODO: Replace exception with async error return values
      # Requires passing the server in local parameters to access the socket

      if paramType.kind == nnkBracketExpr:
        # process array and seq parameters
        # and marshal json arrays to native types
        let paramTypeStr = $paramType[0]
        assert paramTypeStr == "array" or paramTypeStr == "seq"

        type ListFormat = enum ltArray, ltSeq
        let listFormat = if paramTypeStr == "array": ltArray else: ltSeq
        
        if listFormat == ltArray: paramType.expectLen 3 else: paramType.expectLen 2

        var
          listType: NimNode
          checks = newStmtList()
          varDecl: NimNode
        # always include check for array type for parameters
        # TODO: If defined as single params, relax array check
        checks.add quote do:
          if `paramsIdent`.elems[`pos`].kind != JArray:
            raise newException(ValueError, "Expected " & `paramTypeStr` & " but got " & $`paramsIdent`.elems[`pos`].kind)

        case listFormat
        of ltArray:
          let arrayLenStr = paramType[1].repr
          listType = paramType[2]
          varDecl = quote do:
            var `name`: `paramType`
          # arrays can only be up to the defined length
          # note that passing smaller arrays is still valid and are padded with zeros
          checks.add(quote do:
            if `paramsIdent`.elems[`pos`].len > `name`.len:
              raise newException(ValueError, "Provided array is longer than parameter allows. Expected " & `arrayLenStr` & ", data length is " & $`paramsIdent`.elems[`pos`].len)
          )
        of ltSeq:
          listType = paramType[1]
          varDecl = quote do:
            var `name` = newSeq[`listType`](`paramsIdent`.elems[`pos`].len)
        
        let
          getFunc = jsonGetFunc($listType)
          idx = ident"i"
          listParse = quote do:
            for `idx` in 0 ..< `paramsIdent`.elems[`pos`].len:
              `name`[`idx`] = `listType`(`paramsIdent`.elems[`pos`].elems[`idx`].`getFunc`)
        # assemble fetch parameters code
        paramFetch.add(quote do:
          `varDecl`
          `checks`
          `listParse`
        )
      else:
        # other types
        var getFuncName = jsonGetFunc($paramType)
        if not getFuncName.isNil:
          # fetch parameter
          let getFunc = newIdentNode($getFuncName)
          paramFetch.add(quote do:
            var `name`: `paramType` = `paramsIdent`.elems[`pos`].`getFunc`
          )
        else:
          # this type is probably a custom type, eg object
          # bindObj creates assignments to the object fields
          let paramTypeStr = $paramType
          paramFetch.add(quote do:
            var `name`: `paramType`
            if `paramsIdent`.elems[`pos`].kind != JObject:
              raise newException(ValueError, "Expected " & `paramTypeStr` & " but got " & $`paramsIdent`.elems[`pos`].kind)
            
            bindObj(`name`, `paramType`, `paramsIdent`, `pos`)
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
      `paramFetch`
      `procBody`
    `server`.register(`path`, `procName`)
  when defined(nimDumpRpcs):
    echo result.repr
#[
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
  s.on("rpc.seqparam") do(b: string, s: seq[int]):
    var res = newJArray()
    res.add %b
    for item in s:
      res.add %int(item)
    result = res
  type MyObject* = object
    a: int
    b: string
    c: float
  s.on("rpc.objparam") do(b: string, obj: MyObject):
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
        obj = %*{"a": %1, "b": %"hello", "c": %1.23}
        r = waitfor rpcObjParam(%[%"abc", obj])
      check r == obj
    test "Runtime errors":
      expect ValueError:
        discard waitfor rpcArrayParam(%[%[0, 1, 2, 3, 4, 5, 6], %"hello"])
]#