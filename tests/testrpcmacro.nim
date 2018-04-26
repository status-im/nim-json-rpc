import ../ eth-rpc / server / servertypes, unittest, asyncdispatch, json, tables

var s = newRpcServer("localhost")
s.on("rpc.simplepath"):
  echo "hello3"
  result = %1
s.on("rpc.returnint") do() -> int:
  echo "hello2"
s.on("rpc.differentparams") do(a: int, b: string):
  var node = %"test"
  result = node
s.on("rpc.arrayparam") do(arr: array[0..5, byte], b: string):
  var res = newJArray()
  for item in arr:
    res.add %int(item)
  res.add %b
  result = %res
s.on("rpc.seqparam") do(b: string, s: seq[int]):
  var res = newJArray()
  res.add %b
  for item in s:
    res.add %int(item)
  result = res
type MyObject* = object
  a: int
  b: string
  c: float
s.on("rpc.objparam") do(b: string, obj: MyObject):
  result = %obj
suite "Server types":
  test "On macro registration":
    check s.procs.hasKey("rpc.simplepath")
    check s.procs.hasKey("rpc.returnint")
    check s.procs.hasKey("rpc.returnint")
  test "Array/seq parameters":
    let r1 = waitfor rpcArrayParam(%[%[1, 2, 3], %"hello"])
    var ckR1 = %[1, 2, 3, 0, 0, 0]
    ckR1.elems.add %"hello"
    check r1 == ckR1

    let r2 = waitfor rpcSeqParam(%[%"abc", %[1, 2, 3, 4, 5]])
    var ckR2 = %["abc"]
    for i in 0..4: ckR2.add %(i + 1)
    check r2 == ckR2
  test "Object parameters":
    let
      obj = %*{"a": %1, "b": %"hello", "c": %1.23}
      r = waitfor rpcObjParam(%[%"abc", obj])
    check r == obj
  test "Runtime errors":
    expect ValueError:
      discard waitfor rpcArrayParam(%[%[0, 1, 2, 3, 4, 5, 6], %"hello"])
    # TODO: Add other errors