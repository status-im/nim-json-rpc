# ANCHOR: All
# rpc_format.nim

{.push raises: [], gcsafe.}

import
  json_serialization

export
  json_serialization

# ANCHOR: FormatRpcConv
createJsonFlavor RpcConv,
  automaticObjectSerialization = false,
  automaticPrimitivesSerialization = true,
  requireAllFields = false,
  omitOptionalFields = true, # Skip optional fields==none in Writer
  allowUnknownFields = true,
  skipNullFields = true # Skip optional fields==null in Reader
# ANCHOR_END: FormatRpcConv

# ANCHOR_END: All