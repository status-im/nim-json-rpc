# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ../../json_rpc/router

converter toStr*(value: distinct (string|JsonString)): string = string(value)

template `==`*(a: JsonString, b: JsonNode): bool =
  parseJson(string a) == b

template `==`*(a: JsonNode, b: JsonString): bool =
  a == parseJson(string b)
