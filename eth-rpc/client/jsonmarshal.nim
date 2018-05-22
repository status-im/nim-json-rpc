import macros, json, ../ jsonconverters, stint

template expect*(actual, expected: JsonNodeKind, argName: string) =
  if actual != expected: raise newException(ValueError, "Parameter \"" & argName & "\" expected " & $expected & " but got " & $actual)

proc fromJson(n: JsonNode, argName: string, result: var bool) =
  n.kind.expect(JBool, argName)
  result = n.getBool()

proc fromJson(n: JsonNode, argName: string, result: var int) =
  n.kind.expect(JInt, argName)
  result = n.getInt()

# TODO: Why does compiler complain that result cannot be assigned to when using result: var int|var int64
# TODO: Compiler requires forward decl when processing out of module
proc fromJson(n: JsonNode, argName: string, result: var byte)
proc fromJson(n: JsonNode, argName: string, result: var float)
proc fromJson(n: JsonNode, argName: string, result: var string)
proc fromJson[T](n: JsonNode, argName: string, result: var seq[T])
proc fromJson[N, T](n: JsonNode, argName: string, result: var array[N, T])
proc fromJson(n: JsonNode, argName: string, result: var UInt256)
proc fromJson(n: JsonNode, argName: string, result: var int64)
proc fromJson(n: JsonNode, argName: string, result: var ref int64)
proc fromJson(n: JsonNode, argName: string, result: var ref int)
proc fromJson(n: JsonNode, argName: string, result: var ref UInt256)

# TODO: Why can't this be forward declared? Complains of lack of definition
proc fromJson[T: enum](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JInt, argName)
  result = n.getInt().T

# TODO: Why can't this be forward declared? Complains of lack of definition
proc fromJson[T: object](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JObject, argName)
  for k, v in fieldpairs(result):
    fromJson(n[k], k, v)

proc fromJson[T: ref object](n: JsonNode, argName: string, result: var T) =
  n.kind.expect(JObject, argName)
  result = new T
  for k, v in fieldpairs(result[]):
    fromJson(n[k], k, v)

proc fromJson(n: JsonNode, argName: string, result: var int64) =
  n.kind.expect(JInt, argName)
  result = n.getInt()

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

proc fromJson(n: JsonNode, argName: string, result: var UInt256) =
  # expects base 16 string, starting with "0x"
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if hexStr.len > 64 + 2: # including "0x"
    raise newException(ValueError, "Parameter \"" & argName & "\" value too long for UInt256: " & $hexStr.len)
  result = hexStr.parse(StUint[256], 16) # TODO: Handle errors

proc fromJson(n: JsonNode, argName: string, result: var ref UInt256) =
  # expects base 16 string, starting with "0x"
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if hexStr.len > 64 + 2: # including "0x"
    raise newException(ValueError, "Parameter \"" & argName & "\" value too long for UInt256: " & $hexStr.len)
  new result
  result[] = hexStr.parse(StUint[256], 16) # TODO: Handle errors

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

import typetraits
proc unpackArg[T](args: JsonNode, argName: string, argtype: typedesc[T]): T =
  fromJson(args, argName, result)

proc expectArrayLen(node: NimNode, paramsIdent: untyped, length: int) =
  let
    identStr = paramsIdent.repr
    expectedStr = "Expected " & $length & " Json parameter(s) but got "
  node.add(quote do:
    `paramsIdent`.kind.expect(JArray, `identStr`)
    if `paramsIdent`.len != `length`:
      raise newException(ValueError, `expectedStr` & $`paramsIdent`.len)
  )

proc setupParamFromJson*(assignIdent, paramType, jsonIdent: NimNode): NimNode =
  # Add code to verify input and load json parameters into provided Nim type
  result = newStmtList()
  # initial parameter array length check
  # TODO: do this higher up
  #result.expectArrayLen(jsonIdent, nimParameters.len - 1)
  # unpack each parameter and provide assignments
  let paramNameStr = $assignIdent
  result.add(quote do:
    `assignIdent` = `unpackArg`(`jsonIdent`, `paramNameStr`, type(`paramType`))
  )