import macros, servertypes, strutils

var rpcCallRefs {.compiletime.} = newSeq[(string)]()

macro rpc*(prc: untyped): untyped =
  ## Converts a procedure into the following format:
  ##  <proc name>*(params: JsonNode): Future[JsonNode] {.async.}
  ## This procedure is then added into a compile-time list
  ## so that it is automatically registered for every server that
  ## calls registerRpcs(server)
  prc.expectKind nnkProcDef
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
  params[0] = newNimNode(nnkBracketExpr)
  params[0].add ident("Future"), ident("JsonNode")
  params.add identDefs
  # add async pragma, we can assume there isn't an existing .async.
  # as this would fail the result check above.
  prc.addPragma(newIdentNode("async"))

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
  echo result.repr
