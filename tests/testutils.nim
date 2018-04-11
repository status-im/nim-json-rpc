import strutils, eth-rpc/server/private/transportutils, unittest

suite "Encoding":
  test "Encode quantity":
    check 0.encodeQuantity == "0x0"
    check 0x1000.encodeQuantity == "0x1000"
  test "Encode data":
    var i = 0
    for b in bytes(0x07_06_05_04_03_02_01_00'u64):
      check b == i.byte
      i.inc
  test "Encode data pairs":
    for i, b in bytePairs(0x07_06_05_04_03_02_01_00'u64):
      check b == i.byte

