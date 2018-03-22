template ifDebug*(actions: untyped): untyped =
  when not defined(release): actions else: discard