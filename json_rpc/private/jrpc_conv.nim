# json-rpc
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, macros],
  results,
  json_serialization,
  json_serialization/stew/results as jser_results,
  json_serialization/std/[options, sets, tables]

export
  options,
  sets,
  tables,
  json_serialization,
  jser_results

type
  StringOfJson* = JsonString

createJsonFlavor JrpcConv,
  automaticObjectSerialization = true,
  requireAllFields = false

# Avoid templates duplicating the string in the executable.
const errDeserializePrefix = "Error deserializing stream for type '"

template wrapErrors(reader, value, actions: untyped): untyped =
  ## Convert read errors to `UnexpectedValue` for the purpose of marshalling.
  try:
    actions
  except SerializationError as err:
    reader.raiseUnexpectedValue(errDeserializePrefix & $type(value) & "': " & err.msg)

# Bytes.

proc readValue*(r: var JsonReader[JrpcConv], value: var byte) =
  ## Implement separate read serialization for `byte` to avoid
  ## 'can raise Exception' for `readValue(value, uint8)`.
  value = json_serialization.parseInt(r, uint8).byte

proc writeValue*(w: var JsonWriter[JrpcConv], value: byte) =
  json_serialization.writeValue(w, uint8(value))

# Enums.

proc readValue*(r: var JsonReader[JrpcConv], value: var (enum)) =
  wrapErrors r, value:
    value = type(value) json_serialization.readValue(r, uint64)

proc writeValue*(w: var JsonWriter[JrpcConv], value: (enum)) =
  json_serialization.writeValue(w, uint64(value))

# Other base types.

macro genDistinctSerializers(types: varargs[untyped]): untyped =
  ## Implements distinct serialization pass-throughs for `types`.
  result = newStmtList()
  for ty in types:
    result.add(quote do:

      proc readValue*(r: var JsonReader[JrpcConv], value: var `ty`) =
        wrapErrors r, value:
          json_serialization.readValue(r, value)

      proc writeValue*(w: var JsonWriter[JrpcConv], value: `ty`) {.raises: [IOError].} =
        json_serialization.writeValue(w, value)
    )

genDistinctSerializers bool, int, float, string, int64, uint64, uint32, ref int64, ref int

# Sequences and arrays.

proc readValue*[T](r: var JsonReader[JrpcConv], value: var seq[T]) =
  wrapErrors r, value:
    json_serialization.readValue(r, value)

proc writeValue*[T](w: var JsonWriter[JrpcConv], value: seq[T]) =
  json_serialization.writeValue(w, value)

proc readValue*[N: static[int]](r: var JsonReader[JrpcConv], value: var array[N, byte]) =
  ## Read an array while allowing partial data.
  wrapErrors r, value:
    var i = low(value)
    for c in json_serialization.readArray(r, byte):
      if i <= high(value):
        value[i] = c
      inc i
