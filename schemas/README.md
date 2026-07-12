# Discord schema inputs

`discord-api-spec/openapi.json` is the standard (non-preview) OpenAPI 3.1
document from Discord's official `discord/discord-api-spec` repository. The
exact upstream commit and SHA-256 digest are recorded in `schema-lock.json`.
The upstream file is MIT-licensed; its license is kept beside the snapshot.

Discord describes this specification as a public preview and documents known
differences from the developer documentation. `semantic-overlay.json` records
the corrections that Cordnim must apply at its public boundary instead of
silently trusting ambiguous OpenAPI shapes.

The overlay is executable input, not an advisory checklist. The generator
parses each rule into a known semantic/representation pair, expands its
selector against the complete OpenAPI document, and emits one descriptor for
every concrete JSON Pointer. Generation fails when:

- a semantic or representation is unknown or paired incorrectly;
- a selector is malformed;
- any selector alternative matches nothing;
- alternatives overlap; or
- separate rules duplicate or conflict at one location.

Supported selectors deliberately form a small language: exact JSON Pointers
starting with `#/`, recursive suffix selectors starting with `**/`, one `*`
glob inside a path segment, and `|` between alternatives. Extending that
language requires changing and testing the generator rather than silently
accepting a selector it may interpret incorrectly.

A rule's `target` may also be an array of selector strings. Arrays are used
when a semantic applies to a reviewable list of exact locations but a broad
name-based selector would also reach unrelated shapes. Every array element is
still an independent alternative and must match at least once.

Selector matching is followed by semantic-specific shape validation. For
example, `extensible-bits` accepts only scalar string/integer schemas,
`open-enum` accepts only enum arrays with one wire-value kind, and object or
component semantics require an object schema with `properties`. A matching
property name never overrides an incompatible OpenAPI shape; generation fails
with the selector, concrete pointer, expected shape, and observed shape.

The current constraints are checked invariants, not feature switches. Unknown
object fields, enum values, and flag bits must be preserved; optional and
nullable states must remain separate; Components V2 rules must remain enabled;
and the message-component limit must be exactly 40. Changing one of those
contracts requires changing its implementation before the overlay can change.

Regenerate committed raw modules from the repository root:

```fish
nim c -r tools/schema_codegen.nim
```

Check for generated drift without changing files:

```fish
nim c -r tools/schema_codegen.nim -- --check
```

Check mode also scans generator-owned raw directories and top-level schema
artifacts for files carrying the generator marker but missing from the current
output manifest. Such orphan files fail the check. Regeneration reports them
but never deletes them automatically.

The generator reads only these checked-in inputs. It never downloads a moving
schema during a normal build.

Generated semantic data is public through `cordnim/raw`. `semanticRules`
records the source rules and deterministic match counts, while
`semanticDescriptors` maps exact OpenAPI JSON Pointers to semantic kinds,
representations, reasons, component schema names, and nearest property names.
Use `findSemanticDescriptor`, `semanticDescriptorsForSchema`, or
`semanticDescriptorsForProperty` instead of re-parsing the overlay.

The raw model remains the complete original `JsonNode`; descriptors do not
turn generated wrappers into domain objects. Generic JSON-boundary helpers in
`cordnim/raw/model` decode and encode `DiscordField`, `Patch`, typed `Id`,
arbitrary-width `DiscordBits`, and `OpenEnum` only after the caller supplies
the domain type. Component-tree, modal-form, and other application invariants
remain responsibilities of their high-level modules.

`stable-routes.tsv` is the reviewable generated inventory. It contains every
method/path/operation tuple from the pinned standard document together with
the request and successful-response schema labels used by `RawRoute`. A `-`
marks an endpoint without a schema in that column.
