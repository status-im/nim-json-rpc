import stint, ../json_rpc/jsonmarshal

template stintStr(n: UInt256|Int256): JsonNode =
  var s = n.toHex
  if s.len mod 2 != 0: s = "0" & s
  s = "0x" & s
  %s

proc `%`*(n: UInt256): JsonNode = n.stintStr

proc `%`*(n: Int256): JsonNode = n.stintStr

proc writeValue*(w: var JsonWriter[JsonRpc], val: UInt256) =
  writeValue(w, val.stintStr)

proc writeValue*(w: var JsonWriter[JsonRpc], val: ref UInt256) =
  writeValue(w, val[].stintStr)

proc readValue*(r: var JsonReader[JsonRpc], v: var UInt256) =
  ## Allows UInt256 to be passed as a json string.
  ## Expects base 16 string, starting with "0x".
  try:
    let hexStr = r.readValue string
    if hexStr.len > 64 + 2: # including "0x"
      raise newException(ValueError, "Value for '" & $v.type & "' too long for UInt256: " & $hexStr.len)
    v = hexStr.parse(StUint[256], 16) # TODO: Handle errors
  except Exception as err:
    r.raiseUnexpectedValue("Error deserializing for '" & $v.type & "' stream: " & err.msg)

proc readValue*(r: var JsonReader[JsonRpc], v: var ref UInt256) =
  ## Allows ref UInt256 to be passed as a json string.
  ## Expects base 16 string, starting with "0x".
  readValue(r, v[])

