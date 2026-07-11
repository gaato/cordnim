version       = "0.1.0"
author        = "Gakuto Furuya"
description   = "A type-safe Discord application runtime for Nim"
license       = "MPL-2.0"
srcDir        = "src"
bin           = @["cordnim"]

requires "nim >= 2.2.10 & < 2.3.0"
requires "chronos >= 4.0.4 & < 5.0.0"
requires "results >= 0.5.1 & < 0.6.0"
requires "bearssl >= 0.2.11 & < 0.3.0"

task test, "Run the ORC test suite":
  exec "nim c -r --mm:orc" &
    " --nimcache:build/test-runner/cache" &
    " --out:build/test-runner/test_all" &
    " --path:src tests/test_all.nim"

task check, "Compile the public modules without linking":
  exec "nim check --mm:orc --nimcache:build/check --path:src src/cordnim.nim"

task docs, "Build API documentation":
  exec "nim doc --project --mm:orc --path:src --outdir:htmldocs src/cordnim.nim"

task schema, "Regenerate the pinned Discord raw layer":
  exec "nim c -r --mm:orc --nimcache:build/schema/cache" &
    " --out:build/schema/schema_codegen" &
    " --path:src tools/schema_codegen.nim"

task schemaCheck, "Fail if committed generated sources are stale":
  exec "nim c -r --mm:orc --nimcache:build/schema-check/cache" &
    " --out:build/schema-check/schema_codegen" &
    " --path:src tools/schema_codegen.nim -- --check"
