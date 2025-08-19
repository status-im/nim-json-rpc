import chronos, ../errors

template tryImport*(v: untyped): bool =
  # TODO https://github.com/nim-lang/Nim/issues/25108
  template importTest =
    import v
  when compiles(importTest):
    importTest
    true
  else:
    false

from std/net import IPv6_any, IPv4_any

template processResolvedAddresses(what: string) =
  if ips.len == 0:
    # Addresses could not be resolved, critical error.
    raise newException(RpcAddressUnresolvableError, "Unable to resolve " & what)

  var dualStack = Opt.none(Port)
  for ip in ips:
    # Only yield the "any" address once because we try to use dual stack where
    # available
    if ip.toIpAddress() == IPv6_any():
      dualStack = Opt.some(ip.port)
    elif ip.toIpAddress() == IPv4_any() and dualStack == Opt.some(ip.port):
      continue
    yield ip

iterator resolveIP*(
    addresses: openArray[string]
): TransportAddress {.raises: [JsonRpcError].} =
  var ips: seq[TransportAddress]
  # Resolve IPv6 first so that dual stack detection works as expected
  for address in addresses:
    try:
      for resolved in resolveTAddress(address, AddressFamily.IPv6):
        if resolved notin ips:
          ips.add resolved
    except TransportAddressError:
      discard

  for address in addresses:
    try:
      for resolved in resolveTAddress(address, AddressFamily.IPv4):
        if resolved notin ips:
          ips.add resolved
    except TransportAddressError:
      discard

  processResolvedAddresses($addresses)

iterator resolveIP*(
    address: string, port: Port
): TransportAddress {.raises: [JsonRpcError].} =
  var ips: seq[TransportAddress]
  # Resolve IPv6 first so that dual stack detection works as expected
  try:
    for resolved in resolveTAddress(address, port, AddressFamily.IPv6):
      if resolved notin ips:
        ips.add resolved
  except TransportAddressError:
    discard

  try:
    for resolved in resolveTAddress(address, port, AddressFamily.IPv4):
      if resolved notin ips:
        ips.add resolved
  except TransportAddressError:
    discard

  processResolvedAddresses($address & ":" & $port)
