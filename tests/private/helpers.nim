# json-rpc
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  ../../json_rpc/router

converter toStr*(value: distinct (string|JsonString)): string = string(value)

template `==`*(a: JsonString, b: JsonNode): bool =
  parseJson(string a) == b

template `==`*(a: JsonNode, b: JsonString): bool =
  a == parseJson(string b)

when declared(json_serialization.automaticSerialization):
  # Nim 1.6 cannot use this new feature
  JrpcConv.automaticSerialization(int, true)
  JrpcConv.automaticSerialization(string, true)
  JrpcConv.automaticSerialization(array, true)
  JrpcConv.automaticSerialization(byte, true)
  JrpcConv.automaticSerialization(seq, true)
  JrpcConv.automaticSerialization(float, true)
  JrpcConv.automaticSerialization(JsonString, true)
  JrpcConv.automaticSerialization(bool, true)
  JrpcConv.automaticSerialization(int64, true)
  JrpcConv.automaticSerialization(ref, true)
  JrpcConv.automaticSerialization(enum, true)
