from asyncdispatch import Port

proc `$`*(port: Port): string = $int(port)

iterator bytes*[T: SomeUnsignedInt](value: T): byte {.inline.} =
  ## Traverse the bytes of a value in little endian
  yield value.bytePairs[1]

iterator bytePairs*[T: SomeUnsignedInt](value: T): tuple[key: int, val: byte] {.inline.} =
  let argSize = sizeOf(T)
  for bIdx in 0 ..< argSize:
    let
      shift = bIdx.uint * 8
      mask = 0xff'u64 shl shift
    yield (bIdx, byte((value and mask) shr shift))

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc encodeQuantity*(value: SomeUnsignedInt): string =
  var hValue = value.toHex.stripLeadingZeros
  result = "0x" & hValue

# REVIEW: I think Mamy has now introduced a similar proc in the `byteutils` package
proc encodeData*[T: SomeUnsignedInt](values: seq[T]): string =
  ## Translates seq of values to hex string
  let argSize = sizeOf(T)
  result = newString((values.len * argSize) * 2 + 2) # reserve 2 bytes for "0x"
  result[0..1] = "0x"
  var cPos = 0
  for idx, value in values:
    for bValue in values[idx].bytes:
      result[cPos .. cPos + 1] = bValue.int.toHex(2)
      cPos = cPos + 2

