## libFuzzer target for signed component route framing and size limits.

import cordnim/components/routes

proc deterministicSigner(key, message: openArray[byte]): array[32, byte]
    {.gcsafe, raises: [].} =
  # This is a test oracle, not production cryptography.
  for index, value in key:
    result[index mod result.len] = result[index mod result.len] xor value
  for index, value in message:
    result[index mod result.len] = result[index mod result.len] xor value

proc initialize(): cint {.cdecl, exportc: "LLVMFuzzerInitialize".} =
  {.emit: "N_CDECL(void, NimMain)(void); NimMain();".}

proc testOneInput(data: ptr UncheckedArray[byte], len: int): cint {.
    cdecl, exportc: "LLVMFuzzerTestOneInput", raises: [].} =
  result = 0
  var input = newString(len)
  if len > 0:
    copyMem(addr input[0], data, len)
  let codec = RouteCodec(
    activeKeyId: 1,
    keys: @[RouteSigningKey(id: 1, material: @[byte 1, 2, 3, 4])],
    signer: deterministicSigner
  )
  discard codec.decodeRoute(input, 1_700_000_000)
  if len <= 64:
    var payload = newSeq[byte](len)
    if len > 0:
      copyMem(addr payload[0], data, len)
    try:
      let encoded = codec.encodeRoute(7, 1, 1_800_000_000, payload)
      discard codec.decodeRoute(encoded, 1_700_000_000)
    except ValueError:
      discard

when defined(fuzzStandalone):
  import std/[cmdline, syncio]

  stderr.write "StandaloneFuzzTarget: running " & $paramCount() & " inputs\n"
  for index in 1..paramCount():
    var buffer = readFile(paramStr(index))
    discard testOneInput(
      cast[ptr UncheckedArray[byte]](cstring(buffer)), buffer.len
    )
