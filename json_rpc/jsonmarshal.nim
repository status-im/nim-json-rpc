import
  std/[macros, json, typetraits],
  stew/[byteutils, objects],
  json_serialization,
  json_serialization/lexer,
  json_serialization/std/[options, sets, tables]

export json, options, json_serialization

Json.createFlavor Eth1JsonRpc

proc expect*(actual, expected: JsonNodeKind, argName: string) =
  if actual != expected:
    raise newException(
      ValueError, "Parameter [" & argName & "] expected " & $expected & " but got " & $actual)

const errDeserializePrefix = "Error deserializing stream for '"

proc readValue*(r: var JsonReader[Eth1JsonRpc], v: var byte) =
  try:
    v = byte readValue(r, int64)
  except Exception as err:
    r.raiseUnexpectedValue(errDeserializePrefix & $type(v) & "': " & err.msg)

proc readValue*(r: var JsonReader[Eth1JsonRpc], v: var (enum)) =
  try:
    v = type(v) readValue(r, int64)
  except Exception as err:
    r.raiseUnexpectedValue(errDeserializePrefix & $type(v) & "': " & err.msg)

proc readValue*[N: static[int]](r: var JsonReader[Eth1JsonRpc], v: var array[N, byte]) =
  ## Read an array while allowing partial data.
  try:
    r.skipToken tkBracketLe
    if r.lexer.tok != tkBracketRi:
      for i in low(v) .. high(v):
        readValue(r, v[i])
        if r.lexer.tok == tkBracketRi:
          break
        else:
          r.skipToken tkComma
    r.skipToken tkBracketRi
  except Exception as err:
    r.raiseUnexpectedValue(errDeserializePrefix & $type(v) & "': " & err.msg)

proc unpackArg[T](args: JsonNode, argName: string, argtype: typedesc[T]): T {.raises: [ValueError].} =
  if args.isNil:
    raise newException(ValueError, argName & ": unexpected null value")
  try:
    result = Eth1JsonRpc.decode($args, argType)
  except CatchableError as err:
    raise newException(ValueError,
      "Parameter [" & argName & "] of type '" & $argType & "' could not be decoded: " & err.msg)

proc expectArrayLen(node, jsonIdent: NimNode, length: int) =
  let
    identStr = jsonIdent.repr
    expectedStr = "Expected " & $length & " Json parameter(s) but got "
  node.add(quote do:
    `jsonIdent`.kind.expect(JArray, `identStr`)
    if `jsonIdent`.len != `length`:
      raise newException(ValueError, `expectedStr` & $`jsonIdent`.len)
  )

iterator paramsIter(params: NimNode): tuple[name, ntype: NimNode] =
  for i in 1 ..< params.len:
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len-2:
      yield (arg[j], argType)

iterator paramsRevIter(params: NimNode): tuple[name, ntype: NimNode] =
  for i in countdown(params.len-1,1):
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len-2:
      yield (arg[j], argType)

proc isOptionalArg(typeNode: NimNode): bool =
  typeNode.kind == nnkBracketExpr and
    typeNode[0].kind == nnkIdent and
    typeNode[0].strVal == "Option"

proc expectOptionalArrayLen(node, parameters, jsonIdent: NimNode, maxLength: int): int =
  var minLength = maxLength

  for arg, typ in paramsRevIter(parameters):
    if not typ.isOptionalArg: break
    dec minLength

  let
    identStr = jsonIdent.repr
    expectedStr = "Expected at least " & $minLength & " and maximum " & $maxLength & " Json parameter(s) but got "

  node.add(quote do:
    `jsonIdent`.kind.expect(JArray, `identStr`)
    if `jsonIdent`.len < `minLength`:
      raise newException(ValueError, `expectedStr` & $`jsonIdent`.len)
  )

  minLength

proc containsOptionalArg(params: NimNode): bool =
  for n, t in paramsIter(params):
    if t.isOptionalArg:
      return true

proc jsonToNim*(assignIdent, paramType, jsonIdent: NimNode, paramNameStr: string, optional = false): NimNode =
  # verify input and load a Nim type from json data
  # note: does not create `assignIdent`, so can be used for `result` variables
  result = newStmtList()
  # unpack each parameter and provide assignments
  let unpackNode = quote do:
    `unpackArg`(`jsonIdent`, `paramNameStr`, type(`paramType`))

  if optional:
    result.add(quote do: `assignIdent` = some(`unpackNode`))
  else:
    result.add(quote do: `assignIdent` = `unpackNode`)

proc calcActualParamCount(params: NimNode): int =
  # this proc is needed to calculate the actual parameter count
  # not matter what is the declaration form
  # e.g. (a: U, b: V) vs. (a, b: T)
  for n, t in paramsIter(params):
    inc result

proc jsonToNim*(params, jsonIdent: NimNode): NimNode =
  # Add code to verify input and load params into Nim types
  result = newStmtList()
  if not params.isNil:
    var minLength = 0
    if params.containsOptionalArg():
      # more elaborate parameters array check
      minLength = result.expectOptionalArrayLen(params, jsonIdent,
        calcActualParamCount(params))
    else:
      # simple parameters array length check
      result.expectArrayLen(jsonIdent, calcActualParamCount(params))

    # unpack each parameter and provide assignments
    var pos = 0
    for paramIdent, paramType in paramsIter(params):
      # processing multiple variables of one type
      # e.g. (a, b: T), including common (a: U, b: V) form
      let
        paramName = $paramIdent
        jsonElement = quote do:
          `jsonIdent`.elems[`pos`]

      # declare variable before assignment
      result.add(quote do:
        var `paramIdent`: `paramType`
      )

      # e.g. (A: int, B: Option[int], C: string, D: Option[int], E: Option[string])
      if paramType.isOptionalArg:
        let
          innerType = paramType[1]
          innerNode = jsonToNim(paramIdent, innerType, jsonElement, paramName, true)

        if pos >= minLength:
          # allow both empty and null after mandatory args
          # D & E fall into this category
          result.add(quote do:
            if `jsonIdent`.len > `pos` and `jsonElement`.kind != JNull: `innerNode`
          )
        else:
          # allow null param for optional args between/before mandatory args
          # B fall into this category
          result.add(quote do:
            if `jsonElement`.kind != JNull: `innerNode`
          )
      else:
        # mandatory args
        # A and C fall into this category
        # unpack Nim type and assign from json
        result.add jsonToNim(paramIdent, paramType, jsonElement, paramName)

      inc pos
