import unittest, json, tables, chronicles, options
import ../json_rpc/rpcserver

type
  # some nested types to check object parsing
  Test2 = object
    x: array[0..2, int]
    y: string

  Test = object
    a: array[0..1, int]
    b: Test2

  MyObject = object
    a: int
    b: Test
    c: float

  MyOptional = object
    maybeInt: Option[int]

  MyOptionalNotBuiltin = object
    val: Option[Test2]

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

var s = newRpcSocketServer(["localhost:8545"])

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

s.rpc("rpc.multivarsofonetype") do(a, b: string) -> string:
  result = a & " " & b

s.rpc("rpc.optional") do(obj: MyOptional) -> MyOptional:
  result = obj

s.rpc("rpc.optionalArg") do(val: int, obj: Option[MyOptional]) -> MyOptional:
  if obj.isSome():
    result = obj.get()
  else:
    result = MyOptional(maybeInt: some(val))

type
  OptionalFields = object
    a: int
    b: Option[int]
    c: string
    d: Option[int]
    e: Option[string]

s.rpc("rpc.mixedOptionalArg") do(a: int, b: Option[int], c: string,
  d: Option[int], e: Option[string]) -> OptionalFields:

  result.a = a
  result.b = b
  result.c = c
  result.d = d
  result.e = e

s.rpc("rpc.optionalArgNotBuiltin") do(obj: Option[MyOptionalNotBuiltin]) -> string:
  result = "Empty1"
  if obj.isSome:
    let val = obj.get.val
    result = "Empty2"
    if val.isSome:
      result = obj.get.val.get.y

type
  MaybeOptions = object
    o1: Option[bool]
    o2: Option[bool]
    o3: Option[bool]

s.rpc("rpc.optInObj") do(data: string, options: Option[MaybeOptions]) -> int:
  if options.isSome:
    let o = options.get
    if o.o1.isSome: result += 1
    if o.o2.isSome: result += 2
    if o.o3.isSome: result += 4
  
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
    check s.hasMethod("rpc.multivarsofonetype")
    check s.hasMethod("rpc.optionalArg")
    check s.hasMethod("rpc.mixedOptionalArg")
    check s.hasMethod("rpc.optionalArgNotBuiltin")
    check s.hasMethod("rpc.optInObj")

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

  test "Option types":
    let
      inp1 = MyOptional(maybeInt: some(75))
      inp2 = MyOptional()
      r1 = waitfor rpcOptional(%[%inp1])
      r2 = waitfor rpcOptional(%[%inp2])
    check r1 == %inp1
    check r2 == %inp2

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

  test "Multiple variables of one type":
    let r = waitfor rpcMultiVarsOfOneType(%[%"hello", %"world"])
    check r == %"hello world"

  test "Optional arg":
    let
      int1 = MyOptional(maybeInt: some(75))
      int2 = MyOptional(maybeInt: some(117))
      r1 = waitFor rpcOptionalArg(%[%117, %int1])
      r2 = waitFor rpcOptionalArg(%[%117])
    check r1 == %int1
    check r2 == %int2

  test "Mixed optional arg":
    var ax = waitFor rpcMixedOptionalArg(%[%10, %11, %"hello", %12, %"world"])
    check ax == %OptionalFields(a: 10, b: some(11), c: "hello", d: some(12), e: some("world"))
    var bx = waitFor rpcMixedOptionalArg(%[%10, newJNull(), %"hello"])
    check bx == %OptionalFields(a: 10, c: "hello")

  test "Non-built-in optional types":
    let
      t2 = Test2(x: [1, 2, 3], y: "Hello")
      testOpts1 = MyOptionalNotBuiltin(val: some(t2))
      testOpts2 = MyOptionalNotBuiltin()
    var r = waitFor rpcOptionalArgNotBuiltin(%[%testOpts1])
    check r == %t2.y
    var r2 = waitFor rpcOptionalArgNotBuiltin(%[])
    check r2 == %"Empty1"
    var r3 = waitFor rpcOptionalArgNotBuiltin(%[%testOpts2])
    check r3 == %"Empty2"

  test "Manually set up JSON for optionals":
    # Check manual set up json with optionals
    let opts1 = parseJson("""{"o1": true}""")
    var r1 = waitFor rpcOptInObj(%[%"0x31ded", opts1])
    check r1 == %1
    let opts2 = parseJson("""{"o2": true}""")
    var r2 = waitFor rpcOptInObj(%[%"0x31ded", opts2])
    check r2 == %2
    let opts3 = parseJson("""{"o3": true}""")
    var r3 = waitFor rpcOptInObj(%[%"0x31ded", opts3])
    check r3 == %4
    # Combinations
    let opts4 = parseJson("""{"o1": true, "o3": true}""")
    var r4 = waitFor rpcOptInObj(%[%"0x31ded", opts4])
    check r4 == %5
    let opts5 = parseJson("""{"o2": true, "o3": true}""")
    var r5 = waitFor rpcOptInObj(%[%"0x31ded", opts5])
    check r5 == %6
    let opts6 = parseJson("""{"o1": true, "o2": true}""")
    var r6 = waitFor rpcOptInObj(%[%"0x31ded", opts6])
    check r6 == %3

s.stop()
waitFor s.closeWait()

