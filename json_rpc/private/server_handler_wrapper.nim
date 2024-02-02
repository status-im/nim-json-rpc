# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
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
  json_serialization/stew/results,
  ../errors,
  ./jrpc_sys,
  ./shared_wrapper,
  ../jsonmarshal

export
  jsonmarshal

type
  RpcSetup = object
    numFields: int
    numOptionals: int
    minLength: int

{.push gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Optional resolvers
# ------------------------------------------------------------------------------

template rpc_isOptional(_: auto): bool = false
template rpc_isOptional[T](_: results.Opt[T]): bool = true
template rpc_isOptional[T](_: options.Option[T]): bool = true

# ------------------------------------------------------------------------------
# Run time helpers
# ------------------------------------------------------------------------------

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

# ------------------------------------------------------------------------------
# Compile time helpers
# ------------------------------------------------------------------------------
func hasOptionals(setup: RpcSetup): bool {.compileTime.} =
  setup.numOptionals > 0

func rpcSetupImpl[T](val: T): RpcSetup {.compileTime.} =
  ## Counting number of fields, optional fields, and
  ## minimum fields needed by a rpc method
  mixin rpc_isOptional
  var index = 1
  for field in fields(val):
    inc result.numFields
    if rpc_isOptional(field):
      inc result.numOptionals
    else:
      result.minLength = index
    inc index

func rpcSetupFromType(T: type): RpcSetup {.compileTime.} =
  var dummy: T
  rpcSetupImpl(dummy)

template expectOptionalParamsLen(params: RequestParamsRx,
                                 minLength, maxLength: static[int]) =
  ## Make sure positional params with optional fields
  ## meets the handler expectation
  let
    expected = "Expected at least " & $minLength & " and maximum " &
      $maxLength & " Json parameter(s) but got "

  if params.positional.len < minLength:
    raise newException(RequestDecodeError,
      expected & $params.positional.len)

template expectParamsLen(params: RequestParamsRx, length: static[int]) =
  ## Make sure positional params meets the handler expectation
  let
    expected = "Expected " & $length & " Json parameter(s) but got "

  if params.positional.len != length:
    raise newException(RequestDecodeError,
      expected & $params.positional.len)

template setupPositional(setup: static[RpcSetup], params: RequestParamsRx) =
  ## Generate code to check positional params length
  when setup.hasOptionals:
    expectOptionalParamsLen(params, setup.minLength, setup.numFields)
  else:
    expectParamsLen(params, setup.numFields)

template len(params: RequestParamsRx): int =
  params.positional.len

template notNull(params: RequestParamsRx, pos: int): bool =
  params.positional[pos].kind != JsonValueKind.Null

template val(params: RequestParamsRx, pos: int): auto =
  params.positional[pos].param

template unpackPositional(params: RequestParamsRx,
                          paramVar: auto,
                          paramName: static[string],
                          pos: static[int],
                          setup: static[RpcSetup],
                          paramType: type) =
  ## Convert a positional parameter from Json into Nim

  template innerNode() =
    paramVar = unpackArg(params.val(pos), paramName, paramType)

  # e.g. (A: int, B: Option[int], C: string, D: Option[int], E: Option[string])
  when rpc_isOptional(paramVar):
    when pos >= setup.minLength:
      # allow both empty and null after mandatory args
      # D & E fall into this category
      if params.len > pos and params.notNull(pos):
        innerNode()
    else:
      # allow null param for optional args between/before mandatory args
      # B fall into this category
      if params.notNull(pos):
        innerNode()
  else:
    # mandatory args
    # A and C fall into this category
    # unpack Nim type and assign from json
    if params.notNull(pos):
      innerNode()

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
    rpcSetup = ident"rpcSetup"
    handler = makeHandler(handlerName, params, procBody, returnType)
    named = setupNamed(paramsObj, paramsIdent, params)

  if hasParams:
    setup.add makeType(typeName, params)
    setup.add quote do:
      const `rpcSetup` = rpcSetupFromType(`typeName`)
      var `paramsObj`: `typeName`

  # unpack each parameter and provide assignments
  var
    pos = 0
    positional = newStmtList()
    executeParams: seq[NimNode]

  for paramIdent, paramType in paramsIter(params):
    let paramName = $paramIdent
    positional.add quote do:
      unpackPositional(`paramsIdent`,
                       `paramsObj`.`paramIdent`,
                       `paramName`,
                       `pos`,
                       `rpcSetup`,
                       `paramType`)

    executeParams.add quote do:
      `paramsObj`.`paramIdent`
    inc pos

  if hasParams:
    setup.add quote do:
      if `paramsIdent`.kind == rpPositional:
        setupPositional(`rpcSetup`, `paramsIdent`)
        `positional`
      else:
        `named`
  else:
    # even though there is no parameters expected
    # but the numbers of received params should
    # still be checked (RPC spec)
    setup.add quote do:
      if `paramsIdent`.kind == rpPositional:
        expectParamsLen(`paramsIdent`, 0)

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
