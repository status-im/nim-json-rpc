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

proc jsonGetFunc(paramType: string): (NimNode, JsonNodeKind) =
  # Unknown types get attempted as int
  case paramType
  of "string": result = (ident"getStr", JString)
  of "int": result = (ident"getInt", JInt)
  of "float": result = (ident"getFloat", JFloat)
  of "bool": result = (ident"getBool", JBool)
  else:
    if paramType == "byte" or paramType[0..3] == "uint" or paramType[0..2] == "int":
      result = (ident"getInt", JInt)
    else:
      result = (nil, JInt)

proc jsonTranslate(translation: var NimNode, paramType: string): NimNode =
  # TODO: Remove or rework this into `translate`
  case paramType
  of "uint8":
    result = genSym(nskTemplate)
    translation = quote do:
      template `result`(value: int): uint8 =
        if value > 255 or value < 0:
          raise newException(ValueError, "Value out of range of byte, expected 0-255, got " & $value)
        uint8(value and 0xff)
  of "int8":
    result = genSym(nskTemplate)
    translation = quote do:
      template `result`(value: int): uint8 =
        if value > 255 or value < 0:
          raise newException(ValueError, "Value out of range of byte, expected 0-255, got " & $value)
        uint8(value and 0xff)
  else: 
    result = genSym(nskTemplate)
    translation = quote do:
      template `result`(value: untyped): untyped = value

proc expectKind(node, jsonIdent, fieldName: NimNode, tn: JsonNodeKind) =
  let
    expectedStr = "Expected parameter `" & fieldName.repr & "` to be " & $tn & " but got "
    tnIdent = ident($tn)
  node.add(quote do:
    if `jsonIdent`.kind != `tnIdent`:
      raise newException(ValueError, `expectedStr` & $`jsonIdent`.kind)
  )

proc getDigit(s: string): (bool, int) =
  if s.len == 0: return (false, 0)
  for c in s:
    if not c.isDigit: return (false, 0)
  return (true, s.parseInt)


from math import pow

proc translate(paramTypeStr: string, getField: NimNode): NimNode =
  # Add checking and type conversion for more constrained types
  # Note:
  # * specific types add extra run time bounds checking code
  # * types that map one-one get passed as is
  # * any other types get a simple cast, ie; MyType(value) and
  #   get are assumed to be integer.
  #   NOTE: However this will never occur because currently jsonFunc
  #   is required to return nil to process other types.
  # TODO: Allow distinct types
  var paramType = paramTypeStr
  if paramType == "byte": paramType = "uint8"

  case paramType
  of "string", "int", "bool":
    result = quote do: `getField`
  else:
    if paramType[0 .. 3].toLowerAscii == "uint":
      let (numeric, bitSize) = paramType[4 .. high(paramType)].getDigit
      if numeric:
        assert bitSize mod 8 == 0
        let
          maxSize = 1 shl bitSize - 1
          sizeRangeStr = "0 to " & $maxSize
          uintType = ident("uint" & $bitSize)
        result = quote do:
          let x = `getField`
          if x > `maxSize` or x < 0:
            raise newException(ValueError, "Value out of range of byte, expected " & `sizeRangeStr` & ", got " & $x)
          `uintType`(x)
    elif paramType[0 .. 2].toLowerAscii == "int":
      let (numeric, bitSize) = paramType[3 .. paramType.high].getDigit
      if numeric:
        assert bitSize mod 8 == 0
        let
          maxSize = 1 shl (bitSize - 1)
          minVal = -maxSize
          maxVal = maxSize - 1
          sizeRangeStr = $minVal & " to " & $maxVal
          intType = ident("int" & $bitSize)
        result = quote do:
          let x = `getField`
          if x < `minVal` or x > `maxVal`:
            raise newException(ValueError, "Value out of range of byte, expected " & `sizeRangeStr` & ", got " & $x)
          `intType`(x)
    else:
      let nativeParamType = ident(paramTypeStr)
      result = quote do: `nativeParamType`(`getField`)

macro processFields(jsonIdent, fieldName, fieldType: typed): untyped =
  result = newStmtList()
  let
    fieldTypeStr = fieldType.repr.toLowerAscii()
    (jFetch, jKind) = jsonGetFunc(fieldTypeStr)
  
  if not jFetch.isNil:
    # TODO: getType(fieldType) to translate byte -> uint8 and avoid special cases
    result.expectKind(jsonIdent, fieldName, jKind)
    let
      getField = quote do: `jsonIdent`.`jFetch`
      res = translate(`fieldTypeStr`, `getField`)
    result.add(quote do:
      `fieldName` = `res`
    )
  else:
    var fetchedType = getType(fieldType)
    var derivedType: NimNode
    if fetchedType[0].repr == "typeDesc":
      derivedType = getType(fetchedType[1])
    else:
      derivedType = fetchedType
    if derivedType.kind == nnkObjectTy:
      result.expectKind(jsonIdent, fieldName, JObject)
      let recs = derivedType.findChild it.kind == nnkRecList
      for i in 0..<recs.len:
        let
          objFieldName = recs[i]
          objFieldNameStr = objFieldName.toStrLit
          objFieldType = getType(recs[i])
          realType = getType(objFieldType)
          jsonIdentStr = jsonIdent.repr
        result.add(quote do:
          if not `jsonIdent`.hasKey(`objFieldNameStr`):
            raise newException(ValueError, "Cannot find field " & `objFieldNameStr` & " in " & `jsonIdentStr`)
          processFields(`jsonIdent`[`objFieldNameStr`], `fieldName`.`objfieldName`, `realType`)
          )
    elif derivedType.kind == nnkBracketExpr:
      # this should be a seq or array
      result.expectKind(jsonIdent, fieldName, JArray)
      let
        formatType = derivedType[0].repr
        expectedLen = genSym(nskConst)
      var rootType: NimNode
      case formatType
      of "array":
        let
          startLen = derivedType[1][1]
          endLen = derivedType[1][2] 
          expectedParamLen = quote do:
            const `expectedLen` = `endLen` - `startLen` + 1
          expectedLenStr = "Expected parameter `" & fieldName.repr & "` to have a length of "
        # TODO: Note, currently only raising if greater than length, not different size
        result.add(quote do:
          `expectedParamLen`
          if `jsonIdent`.len > `expectedLen`:
            raise newException(ValueError, `expectedLenStr` & $`expectedLen` & " but got " & $`jsonIdent`.len)
        )
        rootType = derivedType[2]
      of "seq":
        result.add(quote do:
          `fieldName` = @[]
          `fieldName`.setLen(`jsonIdent`.len)
        )
        rootType = derivedType[1]
      else:
        raise newException(ValueError, "Cannot determine bracket expression type of \"" & derivedType.treerepr & "\"")
      # add fetch code for array/seq
      var translation: NimNode
      let
        (jFunc, jKind) = jsonGetFunc(($rootType).toLowerAscii)
        transIdent = translation.jsonTranslate($rootType)
      # TODO: Add checks PER ITEM (performance hit!) in the array, if required by the type
      # TODO: Refactor `jsonTranslate` into `translate`
      result.add(quote do:
        `translation`
        for i in 0 ..< `jsonIdent`.len: 
          `fieldName`[i] = `transIdent`(`jsonIdent`.elems[i].`jFunc`)
      )
    else:
      raise newException(ValueError, "Unknown type \"" & derivedType.treerepr & "\"")
  when defined(nimDumpRpcs):
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
      #discard paramType.preParseTypes(paramName, errorCheck)
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
  s.on("rpc.arrayparam") do(arr: array[0..5, byte], b: string):
    var res = newJArray()
    for item in arr:
      res.add %int(item)
    res.add %b
    result = %res
  s.on("rpc.seqparam") do(a: string, s: seq[int]):
    var res = newJArray()
    res.add %a
    for item in s:
      res.add %int(item)
    result = res

  type
    Test2 = object
      x: array[2, int]
    Test = object
      d: array[0..1, int]
      e: Test2

  type MyObject* = object
    a: int
    b: Test
    c: float

  s.on("rpc.objparam") do(a: string, obj: MyObject):
    result = %obj
  s.on("rpc.uinttypes") do(a: byte, b: uint16, c: uint32):
    result = %[int(a), int(b), int(c)]
  s.on("rpc.inttypes") do(a: int8, b: int16, c: int32, d: int8, e: int16, f: int32):
    result = %[int(a), int(b), int(c), int(d), int(e), int(f)]

  suite "Server types":
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
        obj = %*{"a": %1, "b": %*{"d": %[5, 0], "e": %*{"x": %[1, 1]}}, "c": %1.23}
        r = waitfor rpcObjParam(%[%"Test", obj])
      check r == obj
      expect ValueError:
        # here we fail to provide one of the nested fields in json to the rpc
        # TODO: Should this be allowed? We either allow partial non-ambiguous parsing or not
        # Currently, as long as the Nim fields are satisfied, other fields are ignored
        let
          obj = %*{"a": %1, "b": %*{"a": %[5, 0]}, "c": %1.23}
        discard waitFor rpcObjParam(%[%"abc", obj]) # Why doesn't asyncCheck raise?
    test "Uint types":
      let
        testCase = %[%255, %65534, %4294967295]
        r = waitfor rpcUIntTypes(testCase)
      check r == testCase
    test "Int types":
      let
        testCase = %[
          %(127), %(32767), %(2147483647),
          %(-128), %(-32768), %(-2147483648)
        ]
        r = waitfor rpcIntTypes(testCase)
      check r == testCase
    test "Runtime errors":
      expect ValueError:
        echo waitfor rpcArrayParam(%[%[0, 1, 2, 3, 4, 5, 6], %"hello"])

# TODO: Split runtime strictness checking into defines - is there ever a reason to trust input?
# TODO: Add path as constant for each rpc
