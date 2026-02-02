# json-rpc
# Copyright (c) 2019-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  json_serialization, json

type
  FlavorString* = distinct string
  FlavorObj* = object
    s*: FlavorString

proc `==`*(a, b: FlavorString): bool {.borrow.}
proc `%`*(s: FlavorString): JsonNode {.borrow.}

proc init*(T: type FlavorObj, s: string): FlavorObj =
  FlavorObj(s: s.FlavorString)

createJsonFlavor JrpcFlavor,
  automaticObjectSerialization = true,
  automaticPrimitivesSerialization = true

proc readValue*(
    reader: var JrpcFlavor.Reader, value: var FlavorString
) {.gcsafe, raises: [IOError, SerializationError].} =
  value = reader.readValue(string).FlavorString

proc writeValue*(
    writer: var JrpcFlavor.Writer, value: FlavorString
) {.gcsafe, raises: [IOError].} =
  writer.writeValue value.string
