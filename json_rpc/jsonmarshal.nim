import
  std/[macros, json, options, typetraits],
  stew/byteutils

export json, options

proc expect*(actual, expected: JsonNodeKind, argName: string) =
  if actual != expected:
    raise newException(
      ValueError, "Parameter [" & argName & "] expected " & $expected & " but got " & $actual)

proc `%`*(n: ref SomeInteger): JsonNode =
  if n.isNil:
    newJNull()
  else:
    newJInt(n[])

# Compiler requires forward decl when processing out of module
proc fromJson*(n: JsonNode, argName: string, result: var bool)
proc fromJson*(n: JsonNode, argName: string, result: var int)
proc fromJson*(n: JsonNode, argName: string, result: var byte)
proc fromJson*(n: JsonNode, argName: string, result: var float)
proc fromJson*(n: JsonNode, argName: string, result: var string)
proc fromJson*[T](n: JsonNode, argName: string, result: var seq[T])
proc fromJson*[N, T](n: JsonNode, argName: string, result: var array[N, T])
proc fromJson*(n: JsonNode, argName: string, result: var int64)
proc fromJson*(n: JsonNode, argName: string, result: var uint64)
proc fromJson*(n: JsonNode, argName: string, result: var uint32)
proc fromJson*(n: JsonNode, argName: string, result: var ref int64)
proc fromJson*(n: JsonNode, argName: string, result: var ref int)
proc fromJson*[T](n: JsonNode, argName: string, result: var Option[T])

# This can't be forward declared: https://github.com/nim-lang/Nim/issues/7868
proc fromJson*[T: enum](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JInt, argName)
  result = n.getBiggestInt().T

# This can't be forward declared: https://github.com/nim-lang/Nim/issues/7868
proc fromJson*[T: object|tuple](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JObject, argName)
  for k, v in fieldPairs(result):
    if v is Option and not n.hasKey(k):
      fromJson(newJNull(), k, v)
    else:
      fromJson(n[k], k, v)

# same as `proc `%`*[T: object](o: T): JsonNode` in json.nim from the stdlib
# TODO this PR removes the need for this: https://github.com/nim-lang/Nim/pull/14638
proc `%`*[T: tuple](o: T): JsonNode =
  ## Construct JsonNode from tuples and objects.
  result = newJObject()
  for k, v in o.fieldPairs: result[k] = %v

proc fromJson*[T](n: JsonNode, argName: string, result: var Option[T]) =
  # Allow JNull for options
  if n.kind != JNull:
    var val: T
    fromJson(n, argName, val)
    result = some(val)

proc fromJson*(n: JsonNode, argName: string, result: var bool) =
  n.kind.expect(JBool, argName)
  result = n.getBool()

proc fromJson*(n: JsonNode, argName: string, result: var int) =
  n.kind.expect(JInt, argName)
  result = n.getInt()

proc fromJson*[T: ref object](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JObject, argName)
  result = new T
  for k, v in fieldPairs(result[]):
    fromJson(n[k], k, v)

proc fromJson*(n: JsonNode, argName: string, result: var int64) =
  n.kind.expect(JInt, argName)
  result = n.getBiggestInt().int64

proc fromJson*(n: JsonNode, argName: string, result: var uint64) =
  n.kind.expect(JInt, argName)
  let asInt = n.getBiggestInt()
  # signed -> unsigned conversions are unchecked
  # https://github.com/nim-lang/RFCs/issues/175
  if asInt < 0:
    raise newException(
      ValueError, "JSON-RPC input is an unexpected negative value")
  result = uint64(asInt)

proc fromJson*(n: JsonNode, argName: string, result: var uint32) =
  n.kind.expect(JInt, argName)
  let asInt = n.getBiggestInt()
  # signed -> unsigned conversions are unchecked
  # https://github.com/nim-lang/RFCs/issues/175
  if asInt < 0:
    raise newException(
      ValueError, "JSON-RPC input is an unexpected negative value")
  if asInt > BiggestInt(uint32.high()):
    raise newException(
      ValueError, "JSON-RPC input is too large for uint32")

  result = uint32(asInt)

proc fromJson*(n: JsonNode, argName: string, result: var ref int64) =
  n.kind.expect(JInt, argName)
  new result
  result[] = n.getInt()

proc fromJson*(n: JsonNode, argName: string, result: var ref int) =
  n.kind.expect(JInt, argName)
  new result
  result[] = n.getInt()

proc fromJson*(n: JsonNode, argName: string, result: var byte) =
  n.kind.expect(JInt, argName)
  let v = n.getInt()
  if v > 255 or v < 0:
    raise newException(ValueError, "Parameter \"" & argName & "\" value out of range for byte: " & $v)
  result = byte(v)

proc fromJson*(n: JsonNode, argName: string, result: var float) =
  n.kind.expect(JFloat, argName)
  result = n.getFloat()

proc fromJson*(n: JsonNode, argName: string, result: var string) =
  n.kind.expect(JString, argName)
  result = n.getStr()

proc fromJson*[T](n: JsonNode, argName: string, result: var seq[T]) =
  when T is byte:
    if n.kind == JString:
      result = hexToSeqByte n.getStr()
      return

  n.kind.expect(JArray, argName)
  result = newSeq[T](n.len)
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc fromJson*[N, T](n: JsonNode, argName: string, result: var array[N, T]) =
  n.kind.expect(JArray, argName)
  if n.len > result.len:
    raise newException(ValueError, "Parameter \"" & argName & "\" item count is too big for array")
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc unpackArg[T](args: JsonNode, argName: string, argtype: typedesc[T]): T =
  mixin fromJson
  fromJson(args, argName, result)

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
    result.add(quote do: `assignIdent` = `some`(`unpackNode`))
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
