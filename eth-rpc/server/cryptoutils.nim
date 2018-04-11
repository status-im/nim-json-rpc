import nimcrypto

proc k256*(data: string): string =
  # do not convert, assume string is data
  # REVIEW: Nimcrypto has a one-liner for the code here: sha3_256.digest(data)
  var k = sha3_256()
  k.init
  k.update(cast[ptr uint8](data[0].unsafeaddr), data.len.uint)
  result = $finish(k)
