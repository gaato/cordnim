# Changelog

All notable changes are recorded here. Release numbering and compatibility
policy remain undecided; the pinned Discord schema revision is recorded
separately from any future package version.

## Unreleased

- Establish the three-layer `raw`, runtime, and application architecture.
- Pin 242 stable Discord HTTP operations and 538 lossless raw schemas behind a
  checked-in OpenAPI snapshot and semantic overlay.
- Add typed Snowflakes, absent/null/present fields, PATCH values, open enums,
  arbitrary-width flags, and current permission bit names.
- Add Chronos HTTP/TLS, dynamic REST buckets, priority/deadline scheduling,
  bounded idempotent retries, checked errors, and token-free route diagnostics.
- Add signed HTTP interactions, replay rejection, shared HTTP/Gateway command
  routing, deadline-clamped command auto-defer and autocomplete, delivery
  receipts, redacted failure observation, typed component and modal dispatch,
  and install-context visibility policy.
- Add the typed command compiler, nested groups and subcommands, a pinned
  Unicode name grammar, localizations, typed choices and numeric bounds,
  path-aware autocomplete, deterministic manifests and diffs, and the guarded
  `cordnim commands sync` CLI.
- Add distinct Legacy and Components V2 message types, current message fields,
  typed modal forms, BearSSL HMAC routes, and typed migration decoders.
- Add lossless Gateway v10 payload codecs, canonical URLs, persistent
  zlib-stream decoding, fenced coordination, resumable shard runners,
  multi-shard supervision, bounded dispatch, and selective entity caching.
- Add policy-driven cache/REST resolution, process-local collectors, structured
  redacted logs, and stable metric contracts.
- Separate the unassigned build label from the pinned Discord schema identity
  and the Nimble packaging placeholder.
- Add the separate Voice Gateway v8/DAVE package using the official libdave ABI.
- Add ORC Tier 1 CI, raw-schema and Unicode-table drift checks, documentation for
  every public entry module, operator guides, sanitizer fuzz targets, and
  deterministic transport-free tests.
