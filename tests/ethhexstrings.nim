type
  HexQuantityStr* = distinct string
  HexDataStr* = distinct string

# Hex validation

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc encodeQuantity*(value: SomeUnsignedInt): string =
  var hValue = value.toHex.stripLeadingZeros
  result = "0x" & hValue

template hasHexHeader*(value: string | HexDataStr | HexQuantityStr): bool =
  template strVal: untyped = value.string
  if strVal != "" and strVal[0] == '0' and strVal[1] in {'x', 'X'} and strVal.len > 2: true
  else: false

template isHexChar*(c: char): bool =
  if  c notin {'0'..'9'} and
      c notin {'a'..'f'} and
      c notin {'A'..'F'}: false
  else: true

proc validate*(value: HexQuantityStr): bool =
  template strVal: untyped = value.string
  if not value.hasHexHeader:
    return false
  # No leading zeros
  if strVal[2] == '0': return false
  for i in 2..<strVal.len:
    let c = strVal[i]
    if not c.isHexChar:
      return false
  return true

proc validate*(value: HexDataStr): bool =
  template strVal: untyped = value.string
  if not value.hasHexHeader:
    return false
  # Leading zeros are allowed
  for i in 2..<strVal.len:
    let c = strVal[i]
    if not c.isHexChar:
      return false
  # Must be even number of digits
  if strVal.len mod 2 != 0: return false
  return true

# Initialisation

template hexDataStr*(value: string): HexDataStr = value.HexDataStr
template hexQuantityStr*(value: string): HexQuantityStr = value.HexQuantityStr

# Converters

import json
from ../json_rpc/rpcserver import expect

proc `%`*(value: HexDataStr): JsonNode =
  if not value.validate:
    raise newException(ValueError, "HexDataStr: Invalid hex for Ethereum: " & value.string)
  else:
    result = %(value.string)

proc `%`*(value: HexQuantityStr): JsonNode =
  if not value.validate:
    raise newException(ValueError, "HexQuantityStr: Invalid hex for Ethereum: " & value.string)
  else:
    result = %(value.string)

proc fromJson*(n: JsonNode, argName: string, result: var HexDataStr) =
  # Note that '0x' is stripped after validation
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.hexDataStr.validate:
    raise newException(ValueError, "Parameter \"" & argName & "\" value is not valid as a Ethereum data \"" & hexStr & "\"")
  result = hexStr[2..hexStr.high].hexDataStr

proc fromJson*(n: JsonNode, argName: string, result: var HexQuantityStr) =
  # Note that '0x' is stripped after validation
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.hexQuantityStr.validate:
    raise newException(ValueError, "Parameter \"" & argName & "\" value is not valid as an Ethereum hex quantity \"" & hexStr & "\"")
  result = hexStr[2..hexStr.high].hexQuantityStr

# testing

when isMainModule:
  import unittest
  suite "Hex quantity":
    test "Empty string":
      expect ValueError:
        let
          source = ""
          x = hexQuantityStr source
        check %x == %source
    test "Even length":
      let
        source = "0x123"
        x = hexQuantityStr source
      check %x == %source
    test "Odd length":
      let
        source = "0x123"
        x = hexQuantityStr"0x123"
      check %x == %source
    test "Missing header":
      expect ValueError:
        let
          source = "1234"
          x = hexQuantityStr source
        check %x != %source
      expect ValueError:
        let
          source = "01234"
          x = hexQuantityStr source
        check %x != %source
      expect ValueError:
        let
          source = "x1234"
          x = hexQuantityStr source
        check %x != %source
      
  suite "Hex data":
    test "Even length":
      let
        source = "0x1234"
        x = hexDataStr source
      check %x == %source
    test "Odd length":
      expect ValueError:
        let
          source = "0x123"
          x = hexDataStr source
        check %x != %source
    test "Missing header":
      expect ValueError:
        let
          source = "1234"
          x = hexDataStr source
        check %x != %source
      expect ValueError:
        let
          source = "01234"
          x = hexDataStr source
        check %x != %source
      expect ValueError:
        let
          source = "x1234"
          x = hexDataStr source
        check %x != %source
