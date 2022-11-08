import
  ../json_rpc/router

template `==`*(a, b: distinct (string|StringOfJson)): bool =
  string(a) == string(b)

template `==`*(a: StringOfJson, b: JsonNode): bool =
  parseJson(string a) == b

template `==`*(a: JsonNode, b: StringOfJson): bool =
  a == parseJson(string b)

