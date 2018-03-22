import macros, servertypes

var rpcCallRefs {.compiletime.} = newSeq[(string)]()

macro rpc*(prc: untyped): untyped =
  result = prc
  let
    params = prc.findChild(it.kind == nnkFormalParams)
    procName = prc.findChild(it.kind == nnkIdent)

  assert params != nil
  procName.expectKind(nnkIdent)
  for param in params.children:
    if param.kind == nnkIdentDefs:
      if param[1] == ident("JsonNode"):
        return
  var identDefs = newNimNode(nnkIdentDefs)
  identDefs.add ident("params"), ident("JsonNode"), newEmptyNode()
  # check there isn't already a result type
  assert params.len == 1 and params[0].kind == nnkEmpty
  params[0] = ident("JsonNode")
  params.add identDefs
  # Adds to compiletime list of rpc calls so we can register them in bulk
  # for multiple servers using `registerRpcs`.
  rpcCallRefs.add $procName

macro registerRpcs*(server: RpcServer): untyped =
  ## Step through procs currently registered with {.rpc.} and add a register call for server
  result = newNimNode(nnkStmtList)
  result.add newCall(newDotExpr(ident($server), ident("unRegisterAll")))
  for procName in rpcCallRefs:
    let de = newDotExpr(ident($server), ident("register"))
    result.add(newCall(de, newStrLitNode(procName), ident(procName)))
