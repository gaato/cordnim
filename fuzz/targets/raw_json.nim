## libFuzzer target for lossless generated raw JSON models.

import std/json

import cordnim/raw/[model, models/application]

proc initialize(): cint {.cdecl, exportc: "LLVMFuzzerInitialize".} =
  {.emit: "N_CDECL(void, NimMain)(void); NimMain();".}

proc testOneInput(data: ptr UncheckedArray[byte], len: int): cint {.
    cdecl, exportc: "LLVMFuzzerTestOneInput", raises: [].} =
  result = 0
  var input = newString(len)
  if len > 0:
    copyMem(addr input[0], data, len)
  try:
    let parsed = parseJson(input)
    let model = decodeModel(ApplicationResponse, parsed)
    discard model.toJson.unknownFields(["id", "name"])
  except:
    # Bare `except` catches CatchableError but not Defect. Malformed JSON is an
    # expected rejection while sanitizer-visible defects must still crash.
    discard

when defined(fuzzStandalone):
  import std/[cmdline, syncio]

  stderr.write "StandaloneFuzzTarget: running " & $paramCount() & " inputs\n"
  for index in 1..paramCount():
    var buffer = readFile(paramStr(index))
    discard testOneInput(
      cast[ptr UncheckedArray[byte]](cstring(buffer)), buffer.len
    )
