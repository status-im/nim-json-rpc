import ./router, ./server, std/osproc, std/os, std/streams
import strutils, parseutils


type
  StdioRef* = ref object of RpcServer


var process = startProcess(command = "cat" & " " & "test/fixtures/message.txt",
                           workingDir = getCurrentDir(),
                           options = {poUsePath, poEvalCommand})
# process.

proc readMessage(input: Stream): string  =
  # Note: nimlsp debug build will produce debug info to stdout
  var contentLen = -1
  var headerStarted = false
  while not input.atEnd():
    let ln = input.readLine()
    # echo ln & "XX"
    if ln.len != 0:
      let sep = ln.find(':')
      if sep == -1:
        continue
      let valueStart = skipWhitespace(ln, sep + 1) + sep + 1
      case ln[0 ..< sep]
      of "Content-Type":
        if ln.find("utf-8", valueStart) == -1 and ln.find("utf8", valueStart) == -1:
          raise newException(Exception, "only utf-8 is supported")
      of "Content-Length":
        if parseInt(ln, contentLen, valueStart) == 0:
          raise newException(Exception, "invalid Content-Length: " &
            ln.substr(valueStart))
      else:
        # Unrecognized headers are ignored
        continue
      headerStarted = true
    elif not headerStarted:
      continue
    else:
      if contentLen != -1:
        return input.readStr(contentLen)
      else:
        raise newException(Exception, "missing Content-Length header")

let aa = "Content-Length: 8\r\n\r\n[1,2,3]\r\nContent-Length: 8\r\n\r\n[1,2,3]\r\n"
let a = newStringStream(aa);

echo readMessage (a)
