{. warning[UnusedImport]:off .}

import
  ../json_rpc/clients/config

import testhttp, testserverclient, testrpcmacro, testethcalls

when not useNews:
  # TODO The websock server doesn't interop properly
  #      with the news client at the moment
  import testserverclient

when not useNews:
  # The proxy implementation is based on websock
  import testproxy
