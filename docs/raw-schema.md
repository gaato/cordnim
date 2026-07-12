# Raw schema and semantic overlay

`cordnim/raw` exposes the pinned Discord HTTP API without turning generated wire
objects into the application framework. The generated layer favors lossless
round trips and an explicit escape hatch. Higher-level modules own scheduling,
interaction state, cache policy, and application ergonomics.

## Source of truth

The checked-in inputs are:

- `schemas/discord-api-spec/openapi.json`, the pinned Discord OpenAPI document;
- `schemas/schema-lock.json`, the API version, source commit, digests, and
  overlay revision;
- `schemas/semantic-overlay.json`, reviewed corrections for semantics the
  source document cannot express accurately;
- `schemas/stable-routes.tsv`, the reviewed stable HTTP route inventory.

`tools/schema_codegen.nim` reads those files and writes the modules under
`src/cordnim/raw`. Generated files carry a preamble with the snapshot source and
digest. Edit the schema input, overlay, or generator instead of patching a
generated model by hand.

Run both checks after a schema change:

```fish
nimble schema
nimble schemaCheck
```

`schemaCheck` regenerates in memory and compares the expected path set and file
contents. It also rejects an orphan generated file left behind after a schema
or route disappears.

## Semantic descriptors

OpenAPI marks presence and JSON nullability separately from Nim's type system.
It also cannot describe every Discord enum and bit-field compatibility rule.
The semantic overlay maps concrete schema locations to descriptors for:

- Discord snowflake identifiers;
- arbitrary-width bit fields and permission sets;
- PATCH objects that preserve omitted, null, and present values;
- exclusive unions and open enums that retain unknown wire values;
- the irreversible Components V2 transition and legal component trees;
- typed modal form and submission trees.

The generator validates every overlay selector against the pinned input. A rule
with no match or an unexpected match count fails generation. Generated
`cordnim/raw/semantics` data lets tooling inspect the applied semantics without
parsing Nim source.

Schema, operation, semantic-rule, and applied-descriptor counts are emitted in
`cordnim/raw/schema_info`, alongside the lock identities used to generate them.

## Lossless objects

Generated objects preserve fields that the pinned schema does not know yet.
Open enums preserve an unrecognized wire value. Bit fields keep bits above the
largest named constant. This lets an application receive a newer Discord value,
inspect it through the raw layer, and serialize it again without truncation.

`JsonNode` remains a mutable reference type. A raw object's unknown-field map or
raw JSON value belongs to the object that holds it. Copy a node before sharing
it with another task or retaining a mutable alias. Higher-level caches and
interaction response selection create their own serialized or deep-copied
snapshots at their ownership boundaries.

## Routes and requests

Generated route metadata contains the HTTP method, path template, parameter
locations, and major parameter used by Discord rate limits. A route constructor
builds a raw request value. It performs no I/O.

`cordnim/rest/raw_bridge.toRuntimeRequest` renders the path and body into the
runtime request type. The bridge keeps token-bearing paths out of scheduler
diagnostics. Applications can attach priority, deadline, idempotency, retry, and
cancellation policy before submission.

Use the raw route when a semantic wrapper is absent, multipart support is still
raw-only, or a wrapper would hide a Discord field you need. Keep ordinary REST
calls on `cordnim/api` and framework code on `cordnim`,
`cordnim/interactions`, and `cordnim/gateway` so generated declaration changes
do not spread through application code. The raw request should still run through
the supervised REST client.

## Compatibility identity

`discordApiVersion` identifies the HTTP API version. `discordSchemaRevision`,
the specification commit, schema digest, and overlay revision identify the
pinned wire snapshot.

`CordnimBuildLabel` identifies the library build and defaults to the package
version. Deployments may override it with a more specific build identifier. It
does not replace the schema revision. Record both identities when an application
persists raw payloads or reports a compatibility problem.

The generated module docs form the field-level reference. Discord's
[API Reference](https://docs.discord.com/developers/reference) remains the
authority for runtime behavior.
