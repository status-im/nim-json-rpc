import json, stint

iterator bytes*(i: UInt256|Int256): byte =
  let b = cast[ptr array[32, byte]](i.unsafeaddr)
  var pos = 0
  while pos < 32:
    yield b[pos]
    pos += 1

proc `%`*(n: UInt256): JsonNode =
  ## Generic constructor for JSON data. Creates a new `JInt JsonNode`.
  result = newJArray()
  for elem in n.bytes:
    result.add(%int(elem))

proc `%`*(n: Int256): JsonNode =
  ## Generic constructor for JSON data. Creates a new `JInt JsonNode`.
  result = newJArray()
  for elem in n.bytes:
    result.add(%int(elem))

proc `%`*(n: byte): JsonNode =
  ## Generic constructor for JSON data. Creates a new `JInt JsonNode`.
  result = newJInt(int(n))

