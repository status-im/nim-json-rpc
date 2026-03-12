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
  json_serialization/pkg/results as jsresults

export json_serialization, jsresults

# don't mix the json-rpc system encoding with the
# actual response/params encoding
createJsonFlavor JrpcSys,
  automaticObjectSerialization = false,
  requireAllFields = true,
  omitOptionalFields = true, # Skip optional fields==none in Writer
  allowUnknownFields = true,
  skipNullFields = false     # Skip optional fields==null in Reader

proc readJsonRpc2Literal*(r: var JrpcSys.Reader): JsonString
      {.gcsafe, raises: [IOError, SerializationError].} =
  r.parseAsString()

proc writeJsonRpc2Literal*(w: var JrpcSys.Writer, val: JsonString)
      {.gcsafe, raises: [IOError].} =
  w.writeValue val

proc writeNullValue*(w: var JrpcSys.Writer)
       {.gcsafe, raises: [IOError].} =
  w.writeValue JsonString("null")

{.pop.}
