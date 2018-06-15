template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc encodeQuantity*(value: SomeUnsignedInt): string =
  var hValue = value.toHex.stripLeadingZeros
  result = "0x" & hValue

template hasHexHeader*(value: string): bool =
  if value[0] == '0' and value[1] in {'x', 'X'} and value.len > 2: true
  else: false

template isHexChar*(c: char): bool =
  if  c notin {'0'..'9'} and
      c notin {'a'..'f'} and
      c notin {'A'..'F'}: false
  else: true

proc validateHexQuantity*(value: string): bool =
  if not value.hasHexHeader:
    return false
  # No leading zeros
  if value[2] == '0': return false
  for i in 2..<value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  return true

proc validateHexData*(value: string): bool =
  if not value.hasHexHeader:
    return false
  # Leading zeros are allowed
  for i in 2..<value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  # Must be even number of digits
  if value.len mod 2 != 0: return false
  return true
