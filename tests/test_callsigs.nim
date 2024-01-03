# json-rpc
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ../json_rpc/client

from os import getCurrentDir, DirSep
from strutils import rsplit
template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

createRpcSigs(RpcClient, sourceDir & "/private/file_callsigs.nim")

createSingleRpcSig(RpcClient, "bottle"):
  proc get_Bottle(id: int): bool

createRpcSigsFromNim(RpcClient):
  proc get_Banana(id: int): bool
  proc get_Combo(id, index: int, name: string): bool
  proc get_Name(id: int): string
  proc getJsonString(name: string): JsonString
