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
  json_serialization,
  cbor_serialization,
  cbor_serialization/pkg/results as cbor_results,
  stew/byteutils

export cbor_serialization, cbor_results

# XXX disable distinct writer
createCborFlavor CrpcSys,
  automaticObjectSerialization = false,
#  automaticPrimitivesSerialization = false,
  requireAllFields = true,
  omitOptionalFields = true, # Skip optional fields==none in Writer
  allowUnknownFields = true,
  skipNullFields = false     # Skip optional fields==null in Reader

type
  CborString* = JsonString

proc toCborString(value: CborBytes): CborString =
  string.fromBytes(seq[byte](value)).CborString

proc readValue*(r: var CrpcSys.Reader, val: var CborString)
       {.gcsafe, raises: [IOError, SerializationError].} =
  val = r.readValue(CborBytes).toCborString()

proc writeValue*(w: var CrpcSys.Writer, val: CborString)
       {.gcsafe, raises: [IOError].} =
  w.writeValue CborBytes(val.string.toBytes())

proc readJsonRpc2Literal*(r: var CrpcSys.Reader): CborString
       {.gcsafe, raises: [IOError, SerializationError].} =
  r.readValue(string).CborString

proc writeJsonRpc2Literal*(w: var CrpcSys.Writer, val: CborString)
      {.gcsafe, raises: [IOError].} =
  w.writeValue val.string

proc writeNullValue*(w: var CrpcSys.Writer)
      {.gcsafe, raises: [IOError].} =
  w.writeValue cborNull

## Shims for Json compat

proc tokKind*(r: var CrpcSys.Reader): JsonValueKind
       {.gcsafe, raises: [IOError, SerializationError].} =
  case r.parser.cborKind()
  of CborValueKind.Bytes: JsonValueKind.Array
  of CborValueKind.String: JsonValueKind.String
  of CborValueKind.Unsigned, CborValueKind.Negative, CborValueKind.Float: JsonValueKind.Number
  of CborValueKind.Object: JsonValueKind.Object
  of CborValueKind.Array: JsonValueKind.Array
  of CborValueKind.Bool: JsonValueKind.Bool
  of CborValueKind.Null, CborValueKind.Undefined: JsonValueKind.Null
  # This is not quite accurate but it's never checked for these values
  # and we still want to support them in positional paramenters
  of CborValueKind.Tag: JsonValueKind.Number
  of CborValueKind.Simple: JsonValueKind.Number

proc parseAsString*(r: var CrpcSys.Reader): CborString
       {.gcsafe, raises: [IOError, SerializationError].} =
  r.readValue(CborString)

proc parseNull*(r: var CrpcSys.Reader)
       {.gcsafe, raises: [IOError, SerializationError].} =
  discard r.parseSimpleValue()

template writeMember*(w: var CrpcSys.Writer, name: string, value: auto) =
  writeField(w, name, value)

proc writeArray*[C: not void](w: var CrpcSys.Writer, values: C) {.raises: [IOError].} =
  mixin writeValue
  w.writeValue(values)

template beginRecord*(w: var CrpcSys.Writer, _: type) =
  w.beginObject()

template endRecord*(w: var CrpcSys.Writer) =
  w.endObject()

{.pop.}
