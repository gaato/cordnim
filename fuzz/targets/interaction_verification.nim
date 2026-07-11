## libFuzzer target for untrusted HTTP interaction framing.

import std/strutils

import cordnim/interactions/verification

proc acceptingVerifier(publicKey, signature, message: openArray[byte]): bool
    {.gcsafe, raises: [].} =
  publicKey.len == 32 and signature.len == 64 and message.len > 0

proc initialize(): cint {.cdecl, exportc: "LLVMFuzzerInitialize".} =
  {.emit: "N_CDECL(void, NimMain)(void); NimMain();".}

proc testOneInput(data: ptr UncheckedArray[byte], len: int): cint {.
    cdecl, exportc: "LLVMFuzzerTestOneInput", raises: [].} =
  result = 0
  var input = newString(len)
  if len > 0:
    copyMem(addr input[0], data, len)
  let parts = input.split('\0', maxsplit = 2)
  let timestamp = if parts.len > 0: parts[0] else: ""
  let signature = if parts.len > 1: parts[1] else: ""
  let bodyText = if parts.len > 2: parts[2] else: ""
  var body = newSeq[byte](bodyText.len)
  for index, value in bodyText:
    body[index] = byte(ord(value))
  var cache = initReplayCache(maxEntries = 8)
  var config = VerificationConfig(
    allowedSkewSeconds: 300,
    maxBodyBytes: 1_024,
    verifier: acceptingVerifier
  )
  discard config.verifyInteractionRequest(
    cache, signature, timestamp, body, 1_700_000_000
  )

when defined(fuzzStandalone):
  import std/[cmdline, syncio]

  stderr.write "StandaloneFuzzTarget: running " & $paramCount() & " inputs\n"
  for index in 1 .. paramCount():
    var buffer = readFile(paramStr(index))
    discard testOneInput(
      cast[ptr UncheckedArray[byte]](cstring(buffer)), buffer.len
    )
