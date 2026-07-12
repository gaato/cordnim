# Packaging placeholder. The public release version is not assigned yet.
version = "0.0.0"
author = "Gakuto Furuya"
description = "Optional Discord Voice Gateway v8 and DAVE support for cordnim"
license = "MPL-2.0"
srcDir = "src"

requires "nim >= 2.2.10 & < 2.3.0"

task apiCheck, "Compile every public Voice entry without linking":
  exec "nim check --mm:orc --path:src src/cordnim_voice.nim"
  exec "nim check --mm:orc --path:src -d:cordnimVoiceLibdave" &
    " src/cordnim/voice/libdave/raw.nim"

task docs, "Build Voice and native binding documentation":
  let docRoot = getPkgDir() & "/src"
  let docOut = getPkgDir() & "/htmldocs"
  let docCommand = "nim doc --project --docRoot:\"" & docRoot &
    "\" --mm:orc --path:src --outdir:\"" & docOut & "\" "
  exec docCommand & "src/cordnim_voice.nim"
  exec docCommand & "-d:cordnimVoiceLibdave" &
    " src/cordnim/voice/libdave/raw.nim"
