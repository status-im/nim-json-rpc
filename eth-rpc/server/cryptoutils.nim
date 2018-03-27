import nimcrypto

proc k256*(data: string): string =
  # do not convert, assume string is data
  var k = sha3_256()
  k.init
  k.update(cast[ptr uint8](data[0].unsafeaddr), data.len.uint)
  result = $finish(k)
