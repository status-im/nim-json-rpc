import unittest, json, tables, chronicles
import ../rpcsockets

type
  # some nested types to check object parsing
  Test2 = object
    x: array[0..2, int]
    y: string

  Test = object
    a: array[0..1, int]
    b: Test2

  MyObject* = object
    a: int
    b: Test
    c: float
let
  testObj = %*{
    "a": %1,
    "b": %*{
      "a": %[5, 0],
      "b": %*{
        "x": %[1, 2, 3],
        "y": %"test"
      }
    },
    "c": %1.23}

var s = newRpcStreamServer(["localhost:8545"])

# RPC definitions

s.rpc("rpc.simplepath"):
  result = %1

s.rpc("rpc.differentparams") do(a: int, b: string):
  result = %[%a, %b]

s.rpc("rpc.arrayparam") do(arr: array[0..5, byte], b: string):
  var res = %arr
  res.add %b
  result = %res

s.rpc("rpc.seqparam") do(a: string, s: seq[int]):
  var res = newJArray()
  res.add %a
  for item in s:
    res.add %int(item)
  result = res

s.rpc("rpc.objparam") do(a: string, obj: MyObject):
  result = %obj


s.rpc("rpc.returntypesimple") do(i: int) -> int:
  result = i

s.rpc("rpc.returntypecomplex") do(i: int) -> Test2:
  result.x = [1, i, 3]
  result.y = "test"

s.rpc("rpc.testreturns") do() -> int:
  return 1234

# Tests
suite "Server types":

  test "On macro registration":
    check s.hasMethod("rpc.simplepath")
    check s.hasMethod("rpc.differentparams")
    check s.hasMethod("rpc.arrayparam")
    check s.hasMethod("rpc.seqparam")
    check s.hasMethod("rpc.objparam")
    check s.hasMethod("rpc.returntypesimple")
    check s.hasMethod("rpc.returntypecomplex")
    check s.hasMethod("rpc.testreturns")

  test "Simple paths":
    let r = waitFor rpcSimplePath(%[])
    check r == %1

  test "Different param types":
    let
      inp = %[%1, %"abc"]
      r = waitFor rpcDifferentParams(inp)
    check r == inp

  test "Array parameters":
    let r1 = waitfor rpcArrayParam(%[%[1, 2, 3], %"hello"])
    var ckR1 = %[1, 2, 3, 0, 0, 0]
    ckR1.elems.add %"hello"
    check r1 == ckR1

  test "Seq parameters":
    let r2 = waitfor rpcSeqParam(%[%"abc", %[1, 2, 3, 4, 5]])
    var ckR2 = %["abc"]
    for i in 0..4: ckR2.add %(i + 1)
    check r2 == ckR2

  test "Object parameters":
    let r = waitfor rpcObjParam(%[%"abc", testObj])
    check r == testObj

  test "Simple return types":
    let
      inp = %99
      r1 = waitfor rpcReturnTypeSimple(%[%inp])
    check r1 == inp

  test "Complex return types":
    let
      inp = 99
      r1 = waitfor rpcReturnTypeComplex(%[%inp])
    check r1 == %*{"x": %[1, inp, 3], "y": "test"}

  test "Return statement":
    let r = waitFor rpcTestReturns(%[])
    check r == %1234

  test "Runtime errors":
    expect ValueError:
      # root param not array
      discard waitfor rpcArrayParam(%"test")
    expect ValueError:
      # too big for array
      discard waitfor rpcArrayParam(%[%[0, 1, 2, 3, 4, 5, 6], %"hello"])
    expect ValueError:
      # wrong sub parameter type
      discard waitfor rpcArrayParam(%[%"test", %"hello"])
    expect ValueError:
      # wrong param type
      let res = waitFor rpcDifferentParams(%[%"abc", %1])
      # TODO: When errors are proper return values, check error for param name

s.stop()
s.close()
