version       = "0.1.0"
author        = "Gakuto Furuya"
description   = "A type-safe Discord application runtime for Nim"
license       = "MPL-2.0"
srcDir        = "src"
bin           = @["cordnim"]

requires "nim >= 2.2.10 & < 2.3.0"
requires "chronos >= 4.2.0 & < 4.4.0"
requires "results >= 0.5.1 & < 0.6.0"
requires "bearssl >= 0.2.11 & < 0.3.0"
requires "websock >= 0.4.0 & < 0.5.0"
requires "chronicles >= 0.10.2 & < 0.13.0"

task test, "Run the ORC test suite":
  exec "nim c -r --mm:orc" &
    " --nimcache:build/test-runner/cache" &
    " --out:build/test-runner/test_all" &
    " --path:src tests/test_all.nim"

task apiCheck, "Compile every public entry module without linking":
  exec "nim check --mm:orc --nimcache:build/check --path:src src/cordnim.nim"
  exec "nim check --mm:orc --nimcache:build/check --path:src src/cordnim/interactions.nim"
  exec "nim check --mm:orc --nimcache:build/check --path:src src/cordnim/rest.nim"
  exec "nim check --mm:orc --nimcache:build/check --path:src src/cordnim/gateway.nim"
  exec "nim check --mm:orc --nimcache:build/check --path:src src/cordnim/raw.nim"

task docs, "Build documentation for every public entry module":
  let docRoot = getPkgDir() & "/src"
  let docCommand = "nim doc --project --docRoot:\"" & docRoot &
    "\" --mm:orc --path:src --outdir:htmldocs "
  exec docCommand & "src/cordnim.nim"
  exec docCommand & "src/cordnim/interactions.nim"
  exec docCommand & "src/cordnim/rest.nim"
  exec docCommand & "src/cordnim/gateway.nim"
  exec docCommand & "src/cordnim/raw.nim"

task schema, "Regenerate the pinned Discord raw layer":
  exec "nim c -r --mm:orc --nimcache:build/schema --out:build/schema_codegen --path:src tools/schema_codegen.nim"

task schemaCheck, "Fail if committed generated sources are stale":
  exec "nim c -r --mm:orc --nimcache:build/schema-check --out:build/schema_codegen --path:src tools/schema_codegen.nim -- --check"
