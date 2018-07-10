import macros, json

template expect*(actual, expected: JsonNodeKind, argName: string) =
  if actual != expected: raise newException(ValueError, "Parameter \"" & argName & "\" expected " & $expected & " but got " & $actual)

proc `%`*(n: byte{not lit}): JsonNode =
  result = newJInt(int(n))

proc `%`*(n: uint64{not lit}): JsonNode =
  result = newJInt(int(n))

proc `%`*(n: ref int|ref int64): JsonNode =
  result = newJInt(int(n[]))

# Compiler requires forward decl when processing out of module
proc fromJson(n: JsonNode, argName: string, result: var bool)
proc fromJson(n: JsonNode, argName: string, result: var int)
proc fromJson(n: JsonNode, argName: string, result: var byte)
proc fromJson(n: JsonNode, argName: string, result: var float)
proc fromJson(n: JsonNode, argName: string, result: var string)
proc fromJson[T](n: JsonNode, argName: string, result: var seq[T])
proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T])
proc fromJson(n: JsonNode, argName: string, result: var int64)
proc fromJson(n: JsonNode, argName: string, result: var uint64)
proc fromJson(n: JsonNode, argName: string, result: var ref int64)
proc fromJson(n: JsonNode, argName: string, result: var ref int)

# This can't be forward declared: https://github.com/nim-lang/Nim/issues/7868
proc fromJson[T: enum](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JInt, argName)
  result = n.getInt().T

# This can't be forward declared: https://github.com/nim-lang/Nim/issues/7868
proc fromJson[T: object](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JObject, argName)
  for k, v in fieldPairs(result):
    fromJson(n[k], k, v)

proc fromJson(n: JsonNode, argName: string, result: var bool) =
  n.kind.expect(JBool, argName)
  result = n.getBool()

proc fromJson(n: JsonNode, argName: string, result: var int) =
  n.kind.expect(JInt, argName)
  result = n.getInt()

proc fromJson[T: ref object](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JObject, argName)
  result = new T
  for k, v in fieldpairs(result[]):
    fromJson(n[k], k, v)

proc fromJson(n: JsonNode, argName: string, result: var int64) =
  n.kind.expect(JInt, argName)
  result = n.getInt()

proc fromJson(n: JsonNode, argName: string, result: var uint64) =
  n.kind.expect(JInt, argName)
  result = n.getInt().uint64

proc fromJson(n: JsonNode, argName: string, result: var ref int64) =
  n.kind.expect(JInt, argName)
  new result
  result[] = n.getInt()

proc fromJson(n: JsonNode, argName: string, result: var ref int) =
  n.kind.expect(JInt, argName)
  new result
  result[] = n.getInt()

proc fromJson(n: JsonNode, argName: string, result: var byte) =
  n.kind.expect(JInt, argName)
  let v = n.getInt()
  if v > 255 or v < 0: raise newException(ValueError, "Parameter \"" & argName & "\" value out of range for byte: " & $v)
  result = byte(v)

proc fromJson(n: JsonNode, argName: string, result: var float) =
  n.kind.expect(JFloat, argName)
  result = n.getFloat()

proc fromJson(n: JsonNode, argName: string, result: var string) =
  n.kind.expect(JString, argName)
  result = n.getStr()

proc fromJson[T](n: JsonNode, argName: string, result: var seq[T]) =
  n.kind.expect(JArray, argName)
  result = newSeq[T](n.len)
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T]) =
  n.kind.expect(JArray, argName)
  if n.len > result.len: raise newException(ValueError, "Parameter \"" & argName & "\" item count is too big for array")
  for i in 0 ..< n.len:
    fromJson(n[i], argName, result[i])

proc unpackArg[T](args: JsonNode, argName: string, argtype: typedesc[T]): T =
  fromJson(args, argName, result)

proc expectArrayLen(node: NimNode, jsonIdent: untyped, length: int) =
  let
    identStr = jsonIdent.repr
    expectedStr = "Expected " & $length & " Json parameter(s) but got "
  node.add(quote do:
    `jsonIdent`.kind.expect(JArray, `identStr`)
    if `jsonIdent`.len != `length`:
      raise newException(ValueError, `expectedStr` & $`jsonIdent`.len)
  )

proc jsonToNim*(assignIdent, paramType, jsonIdent: NimNode, paramNameStr: string): NimNode =
  # verify input and load a Nim type from json data
  # note: does not create `assignIdent`, so can be used for `result` variables
  result = newStmtList()
  # unpack each parameter and provide assignments
  result.add(quote do:
    `assignIdent` = `unpackArg`(`jsonIdent`, `paramNameStr`, type(`paramType`))
  )

proc jsonToNim*(parameters, jsonIdent: NimNode): NimNode =
  # Add code to verify input and load parameters into Nim types
  result = newStmtList()
  if not parameters.isNil:
    # initial parameter array length check
    result.expectArrayLen(jsonIdent, parameters.len - 1)
    # unpack each parameter and provide assignments
    for i in 1 ..< parameters.len:
      let
        pos = i - 1
        paramIdent = parameters[i][0]
        paramName = $paramIdent
        paramType = parameters[i][1]
        jsonElement = quote do:
          `jsonIdent`.elems[`pos`]
      # declare variable before assignment
      result.add(quote do:
        var `paramIdent`: `paramType`
      )
      # unpack Nim type and assign from json
      result.add jsonToNim(paramIdent, paramType, jsonElement, paramName)

