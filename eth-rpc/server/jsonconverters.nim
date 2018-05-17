import json, stint, strutils

template stintStr(n: UInt256|Int256): JsonNode =
  var s = n.toHex
  if s.len mod 2 != 0: s = "0" & s
  s = "0x" & s
  %s

proc `%`*(n: UInt256): JsonNode = n.stintStr

proc `%`*(n: Int256): JsonNode = n.stintStr

proc `%`*(n: byte{not lit}): JsonNode =
  result = newJInt(int(n))

proc `%`*(n: ref int|ref int64): JsonNode =
  result = newJInt(int(n[]))
