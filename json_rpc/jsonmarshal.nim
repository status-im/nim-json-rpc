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
  json_serialization

export
  json_serialization

createJsonFlavor JrpcConv,
  automaticObjectSerialization = false,
  requireAllFields = false,
  omitOptionalFields = false, # Don't skip optional fields==none in Writer
  allowUnknownFields = true,
  skipNullFields = true,      # Skip optional fields==null in Reader
  automaticPrimitivesSerialization = false

# JrpcConv is a namespace/flavor for encoding and decoding
# parameters and return value of a rpc method.

when declared(automaticSerialization):
  # Nim 1.6 cannot use this new feature
  JrpcConv.automaticSerialization(JsonNode, true)
