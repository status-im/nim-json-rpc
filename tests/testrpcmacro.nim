# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2,
  chronicles,
  ../json_rpc/rpcserver,
  ./private/helpers,
  json_serialization/std/options

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

  MyEnum = enum
    Enum0
    Enum1

  MuscleCar = object
    color: string
    wheel: int

MyObject.useDefaultSerializationIn JrpcConv
Test.useDefaultSerializationIn JrpcConv
Test2.useDefaultSerializationIn JrpcConv
MyOptional.useDefaultSerializationIn JrpcConv
MyOptionalNotBuiltin.useDefaultSerializationIn JrpcConv
MuscleCar.useDefaultSerializationIn JrpcConv

proc readValue*(r: var JsonReader[JrpcConv], val: var MyEnum)
       {.gcsafe, raises: [IOError, SerializationError].} =
  let intVal = r.parseInt(int)
  if intVal < low(MyEnum).int or intVal > high(MyEnum).int:
    r.raiseUnexpectedValue("invalid enum range " & $intVal)
  val = MyEnum(intVal)

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
    "c": %1.0}

var s = newRpcSocketServer(["127.0.0.1:0"])

# RPC definitions
s.rpc("rpc.simplePath"):
  return %1

s.rpc("rpc.enumParam") do(e: MyEnum):
  return %[$e]

s.rpc("rpc.differentParams") do(a: int, b: string):
  return %[%a, %b]

s.rpc("rpc.arrayParam") do(arr: array[0..5, byte], b: string):
  var res = %arr
  res.add %b
  return %res

s.rpc("rpc.seqParam") do(a: string, s: seq[int]):
  var res = newJArray()
  res.add %a
  for item in s:
    res.add %int(item)
  return res

s.rpc("rpc.objParam") do(a: string, obj: MyObject):
  return %obj

s.rpc("rpc.returnTypeSimple") do(i: int) -> int:
  return i

s.rpc("rpc.returnTypeComplex") do(i: int) -> Test2:
  return Test2(x: [1, i, 3], y: "test")

s.rpc("rpc.testReturns") do() -> int:
  return 1234

s.rpc("rpc.multiVarsOfOneType") do(a, b: string) -> string:
  return a & " " & b

s.rpc("rpc.optional") do(obj: MyOptional) -> MyOptional:
  return obj

s.rpc("rpc.optionalArg") do(val: int, obj: Option[MyOptional]) -> MyOptional:
  return if obj.isSome():
    obj.get()
  else:
    MyOptional(maybeInt: some(val))

s.rpc("rpc.optionalArg2") do(a, b: string, c, d: Option[string]) -> string:
  var ret = a & b
  if c.isSome: ret.add c.get()
  if d.isSome: ret.add d.get()
  return ret

s.rpc("echo") do(car: MuscleCar) -> JsonString:
  return JrpcConv.encode(car).JsonString

type
  OptionalFields = object
    a: int
    b: Option[int]
    c: string
    d: Option[int]
    e: Option[string]

OptionalFields.useDefaultSerializationIn JrpcConv

s.rpc("rpc.mixedOptionalArg") do(a: int, b: Option[int], c: string,
  d: Option[int], e: Option[string]) -> OptionalFields:

  result.a = a
  result.b = b
  result.c = c
  result.d = d
  result.e = e

s.rpc("rpc.optionalArgNotBuiltin") do(obj: Option[MyOptionalNotBuiltin]) -> string:
  return if obj.isSome:
    let val = obj.get.val
    if val.isSome:
      obj.get.val.get.y
    else:
      "Empty2"
  else:
    "Empty1"

type
  MaybeOptions = object
    o1: Option[bool]
    o2: Option[bool]
    o3: Option[bool]

MaybeOptions.useDefaultSerializationIn JrpcConv

s.rpc("rpc.optInObj") do(data: string, options: Option[MaybeOptions]) -> int:
  if options.isSome:
    let o = options.get
    if o.o1.isSome: result += 1
    if o.o2.isSome: result += 2
    if o.o3.isSome: result += 4

proc installMoreApiHandlers*(s: RpcServer, prefix: static string) =
  s.rpc(prefix & ".optionalStringArg") do(a: Option[string]) -> string:
    if a.isSome:
      return a.get()
    else:
      return "nope"

s.installMoreApiHandlers("rpc")

# Tests
suite "Server types":
  test "On macro registration":
    check s.hasMethod("rpc.simplePath")
    check s.hasMethod("rpc.differentParams")
    check s.hasMethod("rpc.arrayParam")
    check s.hasMethod("rpc.seqParam")
    check s.hasMethod("rpc.objParam")
    check s.hasMethod("rpc.returnTypeSimple")
    check s.hasMethod("rpc.returnTypeComplex")
    check s.hasMethod("rpc.testReturns")
    check s.hasMethod("rpc.multiVarsOfOneType")
    check s.hasMethod("rpc.optionalArg")
    check s.hasMethod("rpc.mixedOptionalArg")
    check s.hasMethod("rpc.optionalArgNotBuiltin")
    check s.hasMethod("rpc.optInObj")
    check s.hasMethod("rpc.optionalStringArg")

  test "Simple paths":
    let r = waitFor s.executeMethod("rpc.simplePath", %[])
    check r == "1"

  test "Enum param paths":
    block:
      let r = waitFor s.executeMethod("rpc.enumParam", %[%int64(Enum1)])
      check r == "[\"Enum1\"]"

    expect(JsonRpcError):
      discard waitFor s.executeMethod("rpc.enumParam", %[(int64(42))])

  test "Different param types":
    let
      inp = %[%1, %"abc"]
      r = waitFor s.executeMethod("rpc.differentParams", inp)
    check r == inp

  test "Array parameters":
    let r1 = waitFor s.executeMethod("rpc.arrayParam", %[%[1, 2, 3], %"hello"])
    var ckR1 = %[1, 2, 3, 0, 0, 0]
    ckR1.elems.add %"hello"
    check r1 == ckR1

  test "Seq parameters":
    let r2 = waitFor s.executeMethod("rpc.seqParam", %[%"abc", %[1, 2, 3, 4, 5]])
    var ckR2 = %["abc"]
    for i in 0..4: ckR2.add %(i + 1)
    check r2 == ckR2

  test "Object parameters":
    let r = waitFor s.executeMethod("rpc.objParam", %[%"abc", testObj])
    check r == testObj

  test "Simple return types":
    let
      inp = %99
      r1 = waitFor s.executeMethod("rpc.returnTypeSimple", %[%inp])
    check r1 == inp

  test "Complex return types":
    let
      inp = 99
      r1 = waitFor s.executeMethod("rpc.returnTypeComplex", %[%inp])
    check r1 == %*{"x": %[1, inp, 3], "y": "test"}

  test "Option types":
    let
      inp1 = MyOptional(maybeInt: some(75))
      inp2 = MyOptional()
      #r1 = waitFor s.executeMethod("rpc.optional", %[%inp1])
      r2 = waitFor s.executeMethod("rpc.optional", %[%inp2])
    #check r1.string == JrpcConv.encode inp1
    check r2.string == JrpcConv.encode inp2

  test "Return statement":
    let r = waitFor s.executeMethod("rpc.testReturns", %[])
    check r == JrpcConv.encode 1234

  test "Runtime errors":
    expect JsonRpcError:
      # root param not array
      discard waitFor s.executeMethod("rpc.arrayParam", %"test")
    expect JsonRpcError:
      # too big for array
      discard waitFor s.executeMethod("rpc.arrayParam", %[%[0, 1, 2, 3, 4, 5, 6], %"hello"])
    expect JsonRpcError:
      # wrong sub parameter type
      discard waitFor s.executeMethod("rpc.arrayParam", %[%"test", %"hello"])
    expect JsonRpcError:
      # wrong param type
      discard waitFor s.executeMethod("rpc.differentParams", %[%"abc", %1])

  test "Multiple variables of one type":
    let r = waitFor s.executeMethod("rpc.multiVarsOfOneType", %[%"hello", %"world"])
    check r == JrpcConv.encode "hello world"

  test "Optional arg":
    let
      int1 = MyOptional(maybeInt: some(75))
      int2 = MyOptional(maybeInt: some(117))
      r1 = waitFor s.executeMethod("rpc.optionalArg", %[%117, %int1])
      r2 = waitFor s.executeMethod("rpc.optionalArg", %[%117])
      r3 = waitFor s.executeMethod("rpc.optionalArg", %[%117, newJNull()])
    check r1 == JrpcConv.encode int1
    check r2 == JrpcConv.encode int2
    check r3 == JrpcConv.encode int2

  test "Optional arg2":
    let r1 = waitFor s.executeMethod("rpc.optionalArg2", %[%"A", %"B"])
    check r1 == JrpcConv.encode "AB"

    let r2 = waitFor s.executeMethod("rpc.optionalArg2", %[%"A", %"B", newJNull()])
    check r2 == JrpcConv.encode "AB"

    let r3 = waitFor s.executeMethod("rpc.optionalArg2", %[%"A", %"B", newJNull(), newJNull()])
    check r3 == JrpcConv.encode "AB"

    let r4 = waitFor s.executeMethod("rpc.optionalArg2", %[%"A", %"B", newJNull(), %"D"])
    check r4 == JrpcConv.encode "ABD"

    let r5 = waitFor s.executeMethod("rpc.optionalArg2", %[%"A", %"B", %"C", %"D"])
    check r5 == JrpcConv.encode "ABCD"

    let r6 = waitFor s.executeMethod("rpc.optionalArg2", %[%"A", %"B", %"C", newJNull()])
    check r6 == JrpcConv.encode "ABC"

    let r7 = waitFor s.executeMethod("rpc.optionalArg2", %[%"A", %"B", %"C"])
    check r7 == JrpcConv.encode "ABC"

  test "Mixed optional arg":
    var ax = waitFor s.executeMethod("rpc.mixedOptionalArg", %[%10, %11, %"hello", %12, %"world"])
    check ax == JrpcConv.encode OptionalFields(a: 10, b: some(11), c: "hello", d: some(12), e: some("world"))
    var bx = waitFor s.executeMethod("rpc.mixedOptionalArg", %[%10, newJNull(), %"hello"])
    check bx == JrpcConv.encode OptionalFields(a: 10, c: "hello")

  test "Non-built-in optional types":
    let
      t2 = Test2(x: [1, 2, 3], y: "Hello")
      testOpts1 = MyOptionalNotBuiltin(val: some(t2))
      testOpts2 = MyOptionalNotBuiltin()
    var r = waitFor s.executeMethod("rpc.optionalArgNotBuiltin", %[%testOpts1])
    check r == JrpcConv.encode t2.y
    var r2 = waitFor s.executeMethod("rpc.optionalArgNotBuiltin", %[])
    check r2 == JrpcConv.encode "Empty1"
    var r3 = waitFor s.executeMethod("rpc.optionalArgNotBuiltin", %[%testOpts2])
    check r3 == JrpcConv.encode "Empty2"

  test "Manually set up JSON for optionals":
    # Check manual set up json with optionals
    let opts1 = parseJson("""{"o1": true}""")
    var r1 = waitFor s.executeMethod("rpc.optInObj", %[%"0x31ded", opts1])
    check r1 == JrpcConv.encode 1
    let opts2 = parseJson("""{"o2": true}""")
    var r2 = waitFor s.executeMethod("rpc.optInObj", %[%"0x31ded", opts2])
    check r2 == JrpcConv.encode 2
    let opts3 = parseJson("""{"o3": true}""")
    var r3 = waitFor s.executeMethod("rpc.optInObj", %[%"0x31ded", opts3])
    check r3 == JrpcConv.encode 4
    # Combinations
    let opts4 = parseJson("""{"o1": true, "o3": true}""")
    var r4 = waitFor s.executeMethod("rpc.optInObj", %[%"0x31ded", opts4])
    check r4 == JrpcConv.encode 5
    let opts5 = parseJson("""{"o2": true, "o3": true}""")
    var r5 = waitFor s.executeMethod("rpc.optInObj", %[%"0x31ded", opts5])
    check r5 == JrpcConv.encode 6
    let opts6 = parseJson("""{"o1": true, "o2": true}""")
    var r6 = waitFor s.executeMethod("rpc.optInObj", %[%"0x31ded", opts6])
    check r6 == JrpcConv.encode 3

  test "Optional String Arg":
    let
      data = some("some string")
      r1 = waitFor s.executeMethod("rpc.optionalStringArg", %[%data])
      r2 = waitFor s.executeMethod("rpc.optionalStringArg", %[])
      r3 = waitFor s.executeMethod("rpc.optionalStringArg", %[newJNull()])
    echo r1
    echo r2
    echo r3
    check r1 == %data.get()
    check r2 == %"nope"
    check r3 == %"nope"

  test "Null object fields":
    let r = waitFor s.executeMethod("echo", """{"car":{"color":"red",wheel:null}}""".JsonString)
    debugEcho r

s.stop()
waitFor s.closeWait()
