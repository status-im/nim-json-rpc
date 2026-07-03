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

# ANCHOR: FormatUserInfo
type
  UserInfo* = object
    name*: string
    bio*: string

UserInfo.useDefaultSerializationIn RpcConv
# ANCHOR_END: FormatUserInfo

# ANCHOR: FormatUploadData
type
  UploadData* = object
    path*: string
    public*: bool

proc readValue*(
    reader: var RpcConv.Reader, value: var UploadData
) {.gcsafe, raises: [IOError, SerializationError].} =
  let path = reader.readValue(string)
  value = UploadData(path: path, public: false)

proc writeValue*(
    writer: var RpcConv.Writer, value: UploadData
) {.gcsafe, raises: [IOError].} =
  writer.writeValue value.path
# ANCHOR_END: FormatUploadData

# ANCHOR_END: All
