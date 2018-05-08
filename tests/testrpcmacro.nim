import ../ eth-rpc / server / servertypes, unittest, asyncdispatch, json, tables

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

var s = newRpcServer("localhost")

# RPC definitions
s.on("rpc.simplepath"):
  result = %1

s.on("rpc.differentparams") do(a: int, b: string): 
  result = %"test"

s.on("rpc.arrayparam") do(arr: array[0..5, byte], b: string):
  var res = newJArray()
  for item in arr:
    res.add %int(item)
  res.add %b
  result = %res

s.on("rpc.seqparam") do(a: string, s: seq[int]):
  var res = newJArray()
  res.add %a
  for item in s:
    res.add %int(item)
  result = res

s.on("rpc.objparam") do(a: string, obj: MyObject):
  result = %obj

s.on("rpc.returntypesimple") do(i: int) -> int:
  result = i

s.on("rpc.returntypecomplex") do(i: int) -> Test2:
  result.x = [1, i, 3]
  result.y = "test"

# Tests
suite "Server types":

  test "On macro registration":
    check s.procs.hasKey("rpc.simplepath")
    check s.procs.hasKey("rpc.differentparams")
    check s.procs.hasKey("rpc.arrayparam")
    check s.procs.hasKey("rpc.seqparam")
    check s.procs.hasKey("rpc.objparam")
    check s.procs.hasKey("rpc.returntypesimple")
    check s.procs.hasKey("rpc.returntypecomplex")

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
