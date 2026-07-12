# Packaging placeholder. A public release version has not been assigned.
version       = "0.0.0"
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
requires "zlib >= 0.2.0 & < 0.3.0"

const publicEntries = [
  "src/cordnim.nim",
  "src/cordnim/api.nim",
  "src/cordnim/api/applications.nim",
  "src/cordnim/api/channels.nim",
  "src/cordnim/api/fields.nim",
  "src/cordnim/api/gateway_bootstrap.nim",
  "src/cordnim/api/guilds.nim",
  "src/cordnim/api/members.nim",
  "src/cordnim/api/messages.nim",
  "src/cordnim/api/monetization.nim",
  "src/cordnim/api/oauth2.nim",
  "src/cordnim/api/options.nim",
  "src/cordnim/api/threads.nim",
  "src/cordnim/api/webhooks.nim",
  "src/cordnim/app.nim",
  "src/cordnim/app/gateway_config.nim",
  "src/cordnim/app/gateway_interactions.nim",
  "src/cordnim/app/gateway_runtime.nim",
  "src/cordnim/application_manifest.nim",
  "src/cordnim/build_info.nim",
  "src/cordnim/cache.nim",
  "src/cordnim/cli.nim",
  "src/cordnim/collectors.nim",
  "src/cordnim/commands.nim",
  "src/cordnim/components.nim",
  "src/cordnim/core.nim",
  "src/cordnim/gateway.nim",
  "src/cordnim/interactions.nim",
  "src/cordnim/models.nim",
  "src/cordnim/observability.nim",
  "src/cordnim/raw.nim",
  "src/cordnim/rest.nim",
  "src/cordnim/runtime.nim",
  "src/cordnim/testing.nim",
]

task test, "Run the ORC test suite":
  exec "nim c -r --mm:orc" &
    " --nimcache:build/test-runner/cache" &
    " --out:build/test-runner/test_all" &
    " --path:src tests/test_all.nim"

task apiCheck, "Compile every public entry module without linking":
  for entry in publicEntries:
    exec "nim check --mm:orc --nimcache:build/check --path:src " & entry

task docs, "Build documentation for every public entry module":
  let docRoot = getPkgDir() & "/src"
  exec "python3 tools/check_doc_contract.py --clean htmldocs"
  exec "nim doc --project --docRoot:\"" & docRoot &
    "\" --mm:orc --path:src --outdir:htmldocs src/cordnim/doc_index.nim"
  exec "python3 tools/check_doc_contract.py htmldocs"
  exec "python3 tools/check_doc_links.py htmldocs"

task schema, "Regenerate the pinned Discord raw layer":
  exec "nim c -r --mm:orc --nimcache:build/schema --out:build/schema_codegen --path:src tools/schema_codegen.nim"

task schemaCheck, "Fail if committed generated sources are stale":
  exec "nim c -r --mm:orc --nimcache:build/schema-check --out:build/schema_codegen --path:src tools/schema_codegen.nim -- --check"
  exec "python3 tools/gen_name_grammar.py --check"
