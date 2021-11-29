const
  json_rpc_websocket_package {.strdefine.} = "websock"
  useNews* = json_rpc_websocket_package == "news"

when json_rpc_websocket_package notin ["websock", "news"]:
  {.fatal: "json_rpc_websocket_package should be set to either 'websock' or 'news'".}

