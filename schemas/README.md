# Discord schema inputs

`discord-api-spec/openapi.json` is the standard (non-preview) OpenAPI 3.1
document from Discord's official `discord/discord-api-spec` repository. The
exact upstream commit and SHA-256 digest are recorded in `schema-lock.json`.
The upstream file is MIT-licensed; its license is kept beside the snapshot.

Discord describes this specification as a public preview and documents known
differences from the developer documentation. `semantic-overlay.json` records
the corrections that Cordnim must apply at its public boundary instead of
silently trusting ambiguous OpenAPI shapes.

Regenerate committed raw modules from the repository root:

```fish
nim c -r tools/schema_codegen.nim
```

Check for generated drift without changing files:

```fish
nim c -r tools/schema_codegen.nim -- --check
```

The generator reads only these checked-in inputs. It never downloads a moving
schema during a normal build.

`stable-routes.tsv` is the reviewable generated inventory. It contains every
method/path/operation tuple from the pinned standard document together with
the request and successful-response schema labels used by `RawRoute`. A `-`
marks an endpoint without a schema in that column.
