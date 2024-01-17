# json-rpc
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  json_serialization

export
  json_serialization

createJsonFlavor JrpcConv,
  automaticObjectSerialization = false,
  requireAllFields = false,
  omitOptionalFields = true, # Skip optional fields==none in Writer
  allowUnknownFields = true,
  skipNullFields = true      # Skip optional fields==null in Reader
                           
# JrpcConv is a namespace/flavor for encoding and decoding
# parameters and return value of a rpc method.
