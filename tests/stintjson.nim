import json, stint
from ../json_rpc/rpcserver import expect

template stintStr(n: UInt256|Int256): JsonNode =
  var s = n.toHex
  if s.len mod 2 != 0: s = "0" & s
  s = "0x" & s
  %s

proc `%`*(n: UInt256): JsonNode = n.stintStr

proc `%`*(n: Int256): JsonNode = n.stintStr

# allows UInt256 to be passed as a json string
proc fromJson*(n: JsonNode, argName: string, result: var UInt256) =
  # expects base 16 string, starting with "0x"
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if hexStr.len > 64 + 2: # including "0x"
    raise newException(ValueError, "Parameter \"" & argName & "\" value too long for UInt256: " & $hexStr.len)
  result = hexStr.parse(StUint[256], 16) # TODO: Handle errors

# allows ref UInt256 to be passed as a json string
proc fromJson*(n: JsonNode, argName: string, result: var ref UInt256) =
  # expects base 16 string, starting with "0x"
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if hexStr.len > 64 + 2: # including "0x"
    raise newException(ValueError, "Parameter \"" & argName & "\" value too long for UInt256: " & $hexStr.len)
  new result
  result[] = hexStr.parse(StUint[256], 16) # TODO: Handle errors

