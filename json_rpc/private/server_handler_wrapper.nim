# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[macros, typetraits],
  stew/[byteutils, objects],
  json_serialization,
  json_serialization/std/[options],
  ../errors,
  ./jrpc_sys,
  ./shared_wrapper,
  ../jsonmarshal

export
  jsonmarshal

{.push gcsafe, raises: [].}

proc unpackArg(args: JsonString, argName: string, argType: type): argType
                {.gcsafe, raises: [JsonRpcError].} =
  ## This where input parameters are decoded from JSON into
  ## Nim data types
  try:
    result = JrpcConv.decode(args.string, argType)
  except CatchableError as err:
    raise newException(RequestDecodeError,
      "Parameter [" & argName & "] of type '" &
      $argType & "' could not be decoded: " & err.msg)

proc expectArrayLen(node, paramsIdent: NimNode, length: int) =
  ## Make sure positional params meets the handler expectation
  let
    expected = "Expected " & $length & " Json parameter(s) but got "
  node.add quote do:
    if `paramsIdent`.positional.len != `length`:
      raise newException(RequestDecodeError, `expected` &
        $`paramsIdent`.positional.len)

iterator paramsRevIter(params: NimNode): tuple[name, ntype: NimNode] =
  ## Bacward iterator of handler parameters
  for i in countdown(params.len-1,1):
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len-2:
      yield (arg[j], argType)

proc isOptionalArg(typeNode: NimNode): bool =
  # typed version
  (typeNode.kind == nnkCall and
     typeNode.len > 1 and
     typeNode[1].kind in {nnkIdent, nnkSym} and
     typeNode[1].strVal == "Option") or

  # untyped version
  (typeNode.kind == nnkBracketExpr and
    typeNode[0].kind == nnkIdent and
    typeNode[0].strVal == "Option")

proc expectOptionalArrayLen(node: NimNode,
                            parameters: NimNode,
                            paramsIdent: NimNode,
                            maxLength: int): int =
  ## Validate if parameters sent by client meets
  ## minimum expectation of server
  var minLength = maxLength

  for arg, typ in paramsRevIter(parameters):
    if not typ.isOptionalArg: break
    dec minLength

  let
    expected = "Expected at least " & $minLength & " and maximum " &
      $maxLength & " Json parameter(s) but got "

  node.add quote do:
    if `paramsIdent`.positional.len < `minLength`:
      raise newException(RequestDecodeError, `expected` &
        $`paramsIdent`.positional.len)

  minLength

proc containsOptionalArg(params: NimNode): bool =
  ## Is one of handler parameters an optional?
  for n, t in paramsIter(params):
    if t.isOptionalArg:
      return true

proc jsonToNim(paramVar: NimNode,
               paramType: NimNode,
               paramVal: NimNode,
               paramName: string): NimNode =
  ## Convert a positional parameter from Json into Nim
  result = quote do:
    `paramVar` = `unpackArg`(`paramVal`, `paramName`, `paramType`)

proc calcActualParamCount(params: NimNode): int =
  ## this proc is needed to calculate the actual parameter count
  ## not matter what is the declaration form
  ## e.g. (a: U, b: V) vs. (a, b: T)
  for n, t in paramsIter(params):
    inc result

proc makeType(typeName, params: NimNode): NimNode =
  ## Generate type section contains an object definition
  ## with fields of handler params
  let typeSec = quote do:
    type `typeName` = object

  let obj = typeSec[0][2]
  let recList = newNimNode(nnkRecList)
  if params.len > 1:
    for i in 1..<params.len:
      recList.add params[i]
    obj[2] = recList
  typeSec

proc setupPositional(params, paramsIdent: NimNode): (NimNode, int) =
  ## Generate code to check positional params length
  var
    minLength = 0
    code = newStmtList()

  if params.containsOptionalArg():
    # more elaborate parameters array check
    minLength = code.expectOptionalArrayLen(params, paramsIdent,
        calcActualParamCount(params))
  else:
    # simple parameters array length check
    code.expectArrayLen(paramsIdent, calcActualParamCount(params))

  (code, minLength)

proc setupPositional(code: NimNode;
                     paramsObj, paramsIdent, paramIdent, paramType: NimNode;
                     pos, minLength: int) =
  ## processing multiple params of one type
  ## e.g. (a, b: T), including common (a: U, b: V) form
  let
    paramName = $paramIdent
    paramVal = quote do:
      `paramsIdent`.positional[`pos`].param
    paramKind = quote do:
      `paramsIdent`.positional[`pos`].kind
    paramVar = quote do:
      `paramsObj`.`paramIdent`
    innerNode = jsonToNim(paramVar, paramType, paramVal, paramName)

  # e.g. (A: int, B: Option[int], C: string, D: Option[int], E: Option[string])
  if paramType.isOptionalArg:
    if pos >= minLength:
      # allow both empty and null after mandatory args
      # D & E fall into this category
      code.add quote do:
        if `paramsIdent`.positional.len > `pos` and
            `paramKind` != JsonValueKind.Null:
          `innerNode`
    else:
      # allow null param for optional args between/before mandatory args
      # B fall into this category
      code.add quote do:
        if `paramKind` != JsonValueKind.Null:
          `innerNode`
  else:
    # mandatory args
    # A and C fall into this category
    # unpack Nim type and assign from json
    code.add quote do:
      if `paramKind` != JsonValueKind.Null:
        `innerNode`

proc makeParams(retType: NimNode, params: NimNode): seq[NimNode] =
  ## Convert rpc params into handler params
  result.add retType
  if params.len > 1:
    for i in 1..<params.len:
      result.add params[i]

proc makeHandler(procName, params, procBody, returnInner: NimNode): NimNode =
  ## Generate rpc handler proc
  let
    returnType = quote do: Future[`returnInner`]
    paramList = makeParams(returnType, params)
    pragmas = quote do: {.async.}

  result = newProc(
    name = procName,
    params = paramList,
    body = procBody,
    pragmas = pragmas
  )

proc ofStmt(x, paramsObj, paramName, paramType: NimNode): NimNode =
  let caseStr = $paramName
  result = nnkOfBranch.newTree(
    quote do: `caseStr`,
    quote do:
      `paramsObj`.`paramName` = unpackArg(`x`.value, `caseStr`, `paramType`)
  )

proc setupNamed(paramsObj, paramsIdent, params: NimNode): NimNode =
  let x = ident"x"

  var caseStmt = nnkCaseStmt.newTree(
    quote do: `x`.name
  )

  for paramName, paramType in paramsIter(params):
    caseStmt.add ofStmt(x, paramsObj, paramName, paramType)

  caseStmt.add nnkElse.newTree(
    quote do: discard
  )

  result = quote do:
    for `x` in `paramsIdent`.named:
      `caseStmt`

proc wrapServerHandler*(methName: string, params, procBody, procWrapper: NimNode): NimNode =
  ## This proc generate something like this:
  ##
  ## proc rpcHandler(paramA: ParamAType, paramB: ParamBType): Future[ReturnType] =
  ##   procBody
  ##   return retVal
  ##
  ## proc rpcWrapper(params: RequestParamsRx): Future[JsonString] =
  ##   type
  ##     RpcType = object
  ##       paramA: ParamAType
  ##       paramB: ParamBType
  ##
  ##   var rpcVar: RpcType
  ##
  ##   if params.isPositional:
  ##     if params.positional.len < expectedLen:
  ##       raise exception
  ##     rpcVar.paramA = params.unpack(paramA of ParamAType)
  ##     rpcVar.paramB = params.unpack(paramB of ParamBType)
  ##   else:
  ##     # missing parameters is ok in named mode
  ##     # the default value will be used
  ##     for x in params.named:
  ##       case x.name
  ##       of "paramA": rpcVar.paramA = params.unpack(paramA of ParamAType)
  ##       of "paramB": rpcVar.paramB = params.unpack(paramB of ParamBType)
  ##       else: discard
  ##
  ##   let res = await rpcHandler(rpcVar.paramA, rpcVar.paramB)
  ##   return JrpcConv.encode(res).JsonString

  let
    params = params.ensureReturnType()
    setup = newStmtList()
    typeName = genSym(nskType, "RpcType")
    paramsObj = ident"rpcVar"
    handlerName = genSym(nskProc, methName & "_rpcHandler")
    paramsIdent = genSym(nskParam, "rpcParams")
    returnType = params[0]
    hasParams = params.len > 1 # not including return type
    (posSetup, minLength) = setupPositional(params, paramsIdent)
    handler = makeHandler(handlerName, params, procBody, returnType)
    named = setupNamed(paramsObj, paramsIdent, params)

  if hasParams:
    setup.add makeType(typeName, params)
    setup.add quote do:
      var `paramsObj`: `typeName`

  # unpack each parameter and provide assignments
  var
    pos = 0
    positional = newStmtList()
    executeParams: seq[NimNode]

  for paramIdent, paramType in paramsIter(params):
    positional.setupPositional(paramsObj, paramsIdent,
      paramIdent, paramType, pos, minLength)
    executeParams.add quote do:
      `paramsObj`.`paramIdent`
    inc pos

  if hasParams:
    setup.add quote do:
      if `paramsIdent`.kind == rpPositional:
        `posSetup`
        `positional`
      else:
        `named`
  else:
    # even though there is no parameters expected
    # but the numbers of received params should
    # still be checked (RPC spec)
    setup.add quote do:
      if `paramsIdent`.kind == rpPositional:
        `posSetup`

  let
    awaitedResult = ident "awaitedResult"
    doEncode = quote do: encode(JrpcConv, `awaitedResult`)
    maybeWrap =
      if returnType.noWrap: awaitedResult
      else: ident"JsonString".newCall doEncode
    executeCall = newCall(handlerName, executeParams)

  result = newStmtList()
  result.add handler
  result.add quote do:
    proc `procWrapper`(`paramsIdent`: RequestParamsRx): Future[JsonString] {.async, gcsafe.} =
      # Avoid 'yield in expr not lowered' with an intermediate variable.
      # See: https://github.com/nim-lang/Nim/issues/17849
      `setup`
      let `awaitedResult` = await `executeCall`
      return `maybeWrap`
