version = "0.1.0"
author = "Gakuto Furuya"
description = "Optional Discord Voice Gateway v8 and DAVE support for cordnim"
license = "MPL-2.0"
srcDir = "src"

requires "nim >= 2.2.10 & < 2.3.0"

const publicEntries = [
  "src/cordnim_voice.nim",
  "src/cordnim/voice/libdave/raw.nim",
]

task apiCheck, "Compile every public Voice entry without linking":
  exec "nim check --mm:orc --path:src src/cordnim_voice.nim"
  exec "nim check --mm:orc --path:src -d:cordnimVoiceLibdave" &
    " src/cordnim/voice/libdave/raw.nim"

task docs, "Build Voice and native binding documentation":
  let docRoot = getPkgDir() & "/src"
  let docOut = getPkgDir() & "/htmldocs"
  exec "python3 ../tools/check_doc_contract.py --clean voice/htmldocs" &
    " --manifest voice/cordnim_voice.nimble" &
    " --doc-index cordnim/voice/doc_index.html"
  exec "nim doc --project --docRoot:\"" & docRoot &
    "\" --mm:orc --path:src --outdir:\"" & docOut &
    "\" -d:cordnimVoiceLibdave src/cordnim/voice/doc_index.nim"
  exec "python3 ../tools/check_doc_contract.py voice/htmldocs" &
    " --manifest voice/cordnim_voice.nimble" &
    " --doc-index cordnim/voice/doc_index.html"
  exec "python3 ../tools/check_doc_links.py htmldocs"
