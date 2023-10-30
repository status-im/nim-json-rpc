import
  ../json_rpc/router

converter toStr*(value: distinct (string|StringOfJson)): string = string(value)

template `==`*(a: StringOfJson, b: JsonNode): bool =
  parseJson(string a) == b

template `==`*(a: JsonNode, b: StringOfJson): bool =
  a == parseJson(string b)

