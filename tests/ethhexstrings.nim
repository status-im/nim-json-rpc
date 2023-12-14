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

func hasHexHeader*(value: string): bool =
  if value != "" and value[0] == '0' and value[1] in {'x', 'X'} and value.len > 2: true
  else: false

template hasHexHeader*(value: HexDataStr|HexQuantityStr): bool =
  value.string.hasHexHeader

func isHexChar*(c: char): bool =
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
import ../json_rpc/jsonmarshal

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

proc writeValue*(w: var JsonWriter[JsonRpc], val: HexDataStr) {.raises: [IOError].} =
  writeValue(w, val.string)

proc writeValue*(w: var JsonWriter[JsonRpc], val: HexQuantityStr) {.raises: [IOError].} =
  writeValue(w, $val.string)

proc readValue*(r: var JsonReader[JsonRpc], v: var HexDataStr) =
  # Note that '0x' is stripped after validation
  try:
    let hexStr = readValue(r, string)
    if not hexStr.hexDataStr.validate:
      raise newException(ValueError, "Value for '" & $v.type & "' is not valid as a Ethereum data \"" & hexStr & "\"")
    v = hexStr[2..hexStr.high].hexDataStr
  except Exception as err:
    r.raiseUnexpectedValue("Error deserializing for '" & $v.type & "' stream: " & err.msg)

proc readValue*(r: var JsonReader[JsonRpc], v: var HexQuantityStr) =
  # Note that '0x' is stripped after validation
  try:
    let hexStr = readValue(r, string)
    if not hexStr.hexQuantityStr.validate:
      raise newException(ValueError, "Value for '" & $v.type & "' is not valid as a Ethereum data \"" & hexStr & "\"")
    v = hexStr[2..hexStr.high].hexQuantityStr
  except Exception as err:
    r.raiseUnexpectedValue("Error deserializing for '" & $v.type & "' stream: " & err.msg)

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
