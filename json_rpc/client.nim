# json-rpc
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, tables, macros],
  chronos,
  results,
  ./private/jrpc_conv,
  ./private/jrpc_sys,
  ./private/client_handler_wrapper,
  ./private/shared_wrapper,
  ./private/errors

from strutils import replace

export
  chronos,
  tables,
  jrpc_conv,
  RequestParamsTx,
  results

type
  RpcClient* = ref object of RootRef
    awaiting*: Table[RequestId, Future[StringOfJson]]
    lastId: int
    onDisconnect*: proc() {.gcsafe, raises: [].}

  GetJsonRpcRequestHeaders* = proc(): seq[(string, string)] {.gcsafe, raises: [].}

{.push gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func requestTxEncode*(name: string, params: RequestParamsTx, id: RequestId): string =
  let req = requestTx(name, params, id)
  JrpcSys.encode(req)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getNextId*(client: RpcClient): RequestId =
  client.lastId += 1
  RequestId(kind: riNumber, num: client.lastId)

method call*(client: RpcClient, name: string,
             params: RequestParamsTx): Future[StringOfJson]
                {.base, gcsafe, async.} =
  doAssert(false, "`RpcClient.call` not implemented")

method call*(client: RpcClient, name: string,
             params: JsonNode): Future[StringOfJson]
               {.base, gcsafe, async.} =

  await client.call(name, params.paramsTx)

method close*(client: RpcClient): Future[void] {.base, gcsafe, async.} =
  doAssert(false, "`RpcClient.close` not implemented")

proc processMessage*(client: RpcClient, line: string): Result[void, string] =
  # Note: this doesn't use any transport code so doesn't need to be
  # differentiated.
  try:
    let response = JrpcSys.decode(line, ResponseRx)

    if response.jsonrpc.isNone:
      return err("missing or invalid `jsonrpc`")

    if response.id.isNone:
      return err("missing or invalid response id")

    var requestFut: Future[StringOfJson]
    let id = response.id.get
    if not client.awaiting.pop(id, requestFut):
      return err("Cannot find message id \"" & $id & "\"")

    if response.error.isSome:
      let error = JrpcSys.encode(response.error.get)
      requestFut.fail(newException(JsonRpcError, error))
      return ok()

    if response.result.isNone:
      return err("missing or invalid response result")

    requestFut.complete(response.result.get)
    return ok()

  except CatchableError as exc:
    return err(exc.msg)
  except Exception as exc:
    return err(exc.msg)

# ------------------------------------------------------------------------------
# Signature processing
# ------------------------------------------------------------------------------

macro createRpcSigs*(clientType: untyped, filePath: static[string]): untyped =
  ## Takes a file of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  cresteSignaturesFromString(clientType, staticRead($filePath.replace('\\', '/')))

macro createRpcSigsFromString*(clientType: untyped, sigString: static[string]): untyped =
  ## Takes a string of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  cresteSignaturesFromString(clientType, sigString)

macro createSingleRpcSig*(clientType: untyped, alias: static[string], procDecl: typed): untyped =
  ## Takes a single forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  doAssert procDecl.len == 1, "Only accept single proc definition"
  let procDecl = procDecl[0]
  procDecl.expectKind nnkProcDef
  result = createRpcFromSig(clientType, procDecl, ident(alias))

macro createRpcSigsFromNim*(clientType: untyped, procList: typed): untyped =
  ## Takes a list of forward declarations in Nim and builds them into RPC
  ## calls, based on their parameters.
  ## Inputs are marshalled to json, and results are put into the signature's
  ## Nim type.
  processRpcSigs(clientType, procList)

{.pop.}

