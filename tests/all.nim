{. warning[UnusedImport]:off .}

import
  ../json_rpc/clients/config

import
  testrpcmacro, testethcalls, testhttp, testserverclient

when not useNews:
  # The proxy implementation is based on websock
  import testproxy
  import testhook
