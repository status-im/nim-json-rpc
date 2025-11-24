# json-rpc
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/hashes,
  results,
  json_serialization,
  json_serialization/pkg/results as jsresults

export results, json_serialization, jsresults

# This module implements JSON-RPC 2.0 Specification
# https://www.jsonrpc.org/specification

type
  # Special object of Json-RPC 2.0
  JsonRPC2* = object

  RequestParamKind* = enum
    rpPositional
    rpNamed

  ParamDescRx* = object
    kind* : JsonValueKind
    param*: JsonString

  ParamDescNamed* = object
    name*: string
    value*: JsonString

  # Request params received by server
  RequestParamsRx* = object
    case kind*: RequestParamKind
    of rpPositional:
      positional*: seq[ParamDescRx]
    of rpNamed:
      named*: seq[ParamDescNamed]

  # Request params sent by client
  RequestParamsTx* = object
    case kind*: RequestParamKind
    of rpPositional:
      positional*: seq[JsonString]
    of rpNamed:
      named*: seq[ParamDescNamed]

  RequestIdKind* = enum
    riNull
    riNumber
    riString

  RequestId* = object
    case kind*: RequestIdKind
    of riNull:
      discard
    of riNumber:
      num*: int
    of riString:
      str*: string

  ReqRespHeader* = object
    ## Helper type to extract id from message (for example for logging)
    id*      : results.Opt[RequestId]

  # Request received by server
  # TODO used in nim-web3 - remove eventually
  RequestRx* {.deprecated: "ResultsRx2".} = object
    jsonrpc* : results.Opt[JsonRPC2]
    `method`*: results.Opt[string]
    params*  : RequestParamsRx
    id*      : RequestId

  RequestRx2* = object
    jsonrpc* : JsonRPC2
    `method`*: string
    params*  : RequestParamsRx
    id*      : results.Opt[RequestId]

  # Request sent by client
  RequestTx* = object
    jsonrpc* : JsonRPC2
    `method`*: string
    params*  : RequestParamsTx
    id*      : results.Opt[RequestId]

  ResponseError* = object
    code*   : int
    message*: string
    data*   : results.Opt[JsonString]

  ResponseKind* = enum
    rkError
    rkResult

  # Response sent by server
  ResponseTx* = object
    jsonrpc*  : JsonRPC2
    case kind*: ResponseKind
    of rkResult:
      result* : JsonString
    of rkError:
      error*  : ResponseError
    id*       : RequestId

  # Response received by client
  # TODO used in nim-web3 tests
  ResponseRx* {.deprecated.} = object
    jsonrpc*: results.Opt[JsonRPC2]
    id*     : results.Opt[RequestId]
    result* : JsonString
    error*  : results.Opt[ResponseError]

  ResponseRx2* = object
    jsonrpc*: JsonRPC2
    case kind*: ResponseKind
    of rkResult:
      result* : JsonString
    of rkError:
      error*  : ResponseError
    id*     : RequestId

  ReBatchKind* = enum
    rbkSingle
    rbkMany

  RequestBatchRx* = object
    case kind*: ReBatchKind
    of rbkMany:
      many*  : seq[RequestRx2]
    of rbkSingle:
      single*: RequestRx2

  RequestBatchTx* = object
    case kind*: ReBatchKind
    of rbkMany:
      many*  : seq[RequestTx]
    of rbkSingle:
      single*: RequestTx

  ResponseBatchRx* = object
    case kind*: ReBatchKind
    of rbkMany:
      many*  : seq[ResponseRx2]
    of rbkSingle:
      single*: ResponseRx2

  ResponseBatchTx* = object
    case kind*: ReBatchKind
    of rbkMany:
      many*  : seq[ResponseTx]
    of rbkSingle:
      single*: ResponseTx

# don't mix the json-rpc system encoding with the
# actual response/params encoding
createJsonFlavor JrpcSys,
  automaticObjectSerialization = false,
  requireAllFields = true,
  omitOptionalFields = true, # Skip optional fields==none in Writer
  allowUnknownFields = true,
  skipNullFields = false     # Skip optional fields==null in Reader

ResponseError.useDefaultSerializationIn JrpcSys
RequestTx.useDefaultWriterIn JrpcSys
RequestRx.useDefaultReaderIn JrpcSys
RequestRx2.useDefaultReaderIn JrpcSys
ReqRespHeader.useDefaultReaderIn JrpcSys

const
  JsonRPC2Literal = JsonString("\"2.0\"")
  MaxIdStringLength = 256
    ## Maximum length of id, when represented as a string (to avoid spam)

func hash*(x: RequestId): hashes.Hash =
  var h = 0.Hash
  case x.kind:
  of riNumber: h = h !& hash(x.num)
  of riString: h = h !& hash(x.str)
  of riNull: h = h !& hash("null")
  result = !$(h)

func `$`*(x: RequestId): string =
  case x.kind:
  of riNumber: $x.num
  of riString: x.str
  of riNull: "null"

func `==`*(a, b: RequestId): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of riNumber: a.num == b.num
  of riString: a.str == b.str
  of riNull: true

func meth*(rx: RequestRx | RequestRx2): string =
  rx.`method`

template shouldWriteObjectField*(field: RequestParamsTx): bool =
  case field.kind
  of rpPositional:
    field.positional.len > 0
  of rpNamed:
    field.named.len > 0

func isFieldExpected*(_: type RequestParamsRx): bool {.compileTime.} =
  # A Structured value that holds the parameter values to be used during the
  # invocation of the method. This member MAY be omitted.

  false

proc readValue*(r: var JsonReader[JrpcSys], val: var JsonRPC2)
      {.gcsafe, raises: [IOError, JsonReaderError].} =
  let version = r.parseAsString()
  if version != JsonRPC2Literal:
    r.raiseUnexpectedValue("Invalid JSON-RPC version, want=" &
      JsonRPC2Literal.string & " got=" & version.string)

proc readValue*(
    r: var JsonReader, value: var results.Opt[RequestId]
) {.raises: [IOError, SerializationError].} =
  # Unlike the default reader in `results`, pass `null` to RequestId reader that
  # will handle it
  mixin readValue

  value.ok r.readValue(RequestId)

proc writeValue*(w: var JsonWriter[JrpcSys], val: JsonRPC2)
      {.gcsafe, raises: [IOError].} =
  w.writeValue JsonRPC2Literal

proc readValue*(r: var JsonReader[JrpcSys], val: var RequestId)
      {.gcsafe, raises: [IOError, JsonReaderError].} =
  let tok = r.tokKind
  case tok
  of JsonValueKind.Number:
    val = RequestId(kind: riNumber, num: r.parseInt(int))
  of JsonValueKind.String:
    val = RequestId(kind: riString, str: r.parseString(MaxIdStringLength))
  of JsonValueKind.Null:
    val = RequestId(kind: riNull)
    r.parseNull()
  else:
    r.raiseUnexpectedValue("Invalid RequestId, must be Number, String, or Null, got=" & $tok)

proc writeValue*(w: var JsonWriter[JrpcSys], val: RequestId)
       {.gcsafe, raises: [IOError].} =
  case val.kind
  of riNumber: w.writeValue val.num
  of riString: w.writeValue val.str
  of riNull:   w.writeValue JsonString("null")

proc readValue*(r: var JsonReader[JrpcSys], val: var RequestParamsRx)
       {.gcsafe, raises: [IOError, SerializationError].} =
  let tok = r.tokKind
  case tok
  of JsonValueKind.Array:
    val = RequestParamsRx(kind: rpPositional)
    r.parseArray:
      val.positional.add ParamDescRx(
        kind: r.tokKind(),
        param: r.parseAsString(),
      )
  of JsonValueKind.Object:
    val = RequestParamsRx(kind: rpNamed)
    for key in r.readObjectFields():
      val.named.add ParamDescNamed(
        name: key,
        value: r.parseAsString(),
      )
  else:
    r.raiseUnexpectedValue("RequestParam must be either array or object, got=" & $tok)

proc writeValue*(w: var JsonWriter[JrpcSys], val: RequestParamsTx)
      {.gcsafe, raises: [IOError].} =
  case val.kind
  of rpPositional:
    w.writeArray val.positional
  of rpNamed:
    w.beginRecord RequestParamsTx
    for x in val.named:
      w.writeField(x.name, x.value)
    w.endRecord()

proc writeValue*(w: var JsonWriter[JrpcSys], val: ResponseTx)
       {.gcsafe, raises: [IOError].} =
  w.beginRecord ResponseTx
  w.writeField("jsonrpc", val.jsonrpc)
  w.writeField("id", val.id)
  if val.kind == rkResult:
    w.writeField("result", val.result)
  else:
    w.writeField("error", val.error)
  w.endRecord()

proc readValue*(r: var JsonReader[JrpcSys], val: var ResponseRx)
       {.gcsafe, raises: [IOError, SerializationError].} =
  # We need to overload ResponseRx reader because
  # we don't want to skip null fields
  r.parseObjectWithoutSkip(key):
    case key
    of "jsonrpc": r.readValue(val.jsonrpc)
    of "id"     : r.readValue(val.id)
    of "result" : val.result = r.parseAsString()
    of "error"  : r.readValue(val.error)
    else: discard

proc readValue*(r: var JsonReader[JrpcSys], val: var ResponseRx2)
       {.gcsafe, raises: [IOError, SerializationError].} =
  # https://www.jsonrpc.org/specification#response_object

  var
    jsonrpcOpt: Opt[JsonRPC2]
    idOpt: Opt[RequestId]
    resultOpt: Opt[JsonString]
    errorOpt: Opt[ResponseError]

  r.parseObjectWithoutSkip(key):
    case key
    of "jsonrpc": r.readValue(jsonrpcOpt)
    of "id"     : r.readValue(idOpt)
    of "result" : resultOpt.ok r.parseAsString()
    of "error"  : r.readValue(errorOpt)
    else: discard

  if jsonrpcOpt.isNone:
    r.raiseIncompleteObject("Missing or invalid `jsonrpc` version")
  let id = idOpt.valueOr:
    r.raiseIncompleteObject("Missing `id` field")

  if resultOpt.isNone() and errorOpt.isNone():
    r.raiseIncompleteObject("Missing `result` or `error` field")

  if errorOpt.isSome():
    if resultOpt.isSome():
      r.raiseUnexpectedValue("Both `result` and `error` fields present")

    val = ResponseRx2(id: id, kind: ResponseKind.rkError, error: move(errorOpt[]))
  else:
    val = ResponseRx2(id: id, kind: ResponseKind.rkResult, result: move(resultOpt[]))

proc writeValue*(w: var JsonWriter[JrpcSys], val: RequestBatchTx)
       {.gcsafe, raises: [IOError].} =
  if val.kind == rbkMany:
    w.writeArray(val.many)
  else:
    w.writeValue(val.single)

proc readValue*(r: var JsonReader[JrpcSys], val: var RequestBatchRx)
       {.gcsafe, raises: [IOError, SerializationError].} =
  let tok = r.tokKind
  case tok
  of JsonValueKind.Array:
    val = RequestBatchRx(kind: rbkMany)
    r.readValue(val.many)
    if val.many.len == 0:
      r.raiseUnexpectedValue("Batch must contain at least one message")
  of JsonValueKind.Object:
    val = RequestBatchRx(kind: rbkSingle)
    r.readValue(val.single)
  else:
    r.raiseUnexpectedValue("RequestBatch must be either array or object, got=" & $tok)

proc writeValue*(w: var JsonWriter[JrpcSys], val: ResponseBatchTx)
       {.gcsafe, raises: [IOError].} =
  if val.kind == rbkMany:
    w.writeArray(val.many)
  else:
    w.writeValue(val.single)

proc readValue*(r: var JsonReader[JrpcSys], val: var ResponseBatchRx)
       {.gcsafe, raises: [IOError, SerializationError].} =
  let tok = r.tokKind
  case tok
  of JsonValueKind.Array:
    val = ResponseBatchRx(kind: rbkMany)
    r.readValue(val.many)
    if val.many.len == 0:
      r.raiseUnexpectedValue("Batch must contain at least one message")
  of JsonValueKind.Object:
    val = ResponseBatchRx(kind: rbkSingle)
    r.readValue(val.single)
  else:
    r.raiseUnexpectedValue("ResponseBatch must be either array or object, got=" & $tok)

func toTx*(params: RequestParamsRx): RequestParamsTx =
  case params.kind:
  of rpPositional:
    result = RequestParamsTx(kind: rpPositional)
    for x in params.positional:
      result.positional.add x.param
  of rpNamed:
    result = RequestParamsTx(kind: rpNamed)
    result.named = params.named

template writeRequest*(writer: var JrpcSys.Writer, name: string, params: RequestParamsTx, id: int) =
  writer.writeObject:
    writer.writeMember("jsonrpc", JsonRPC2())
    writer.writeMember("id", id)
    writer.writeMember("method", name)
    writer.writeMember("params", params)

template withWriter*(_: type JrpcSys, writer, body: untyped): seq[byte] =
  var stream = memoryOutput()

  {.cast(noSideEffect), cast(raises: []).}:
    var writer = JrpcSys.Writer.init(stream)
    body

  stream.getOutput(seq[byte])

{.pop.}
