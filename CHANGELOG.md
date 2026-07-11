# Changelog

All notable changes are recorded here. The project uses Semantic Versioning for
the high-level API and publishes the pinned Discord schema revision separately.

## 0.1.0 - unreleased

- Establish the three-layer `raw`, runtime, and application architecture.
- Pin 242 stable Discord HTTP operations and 538 lossless raw schemas behind a
  checked-in OpenAPI snapshot and semantic overlay.
- Add typed Snowflakes, absent/null/present fields, PATCH values, open enums,
  arbitrary-width flags, and current permission bit names.
- Add Chronos HTTP/TLS, dynamic REST buckets, priority/deadline scheduling,
  bounded idempotent retries, checked errors, and token-free route diagnostics.
- Add signed HTTP interactions, replay rejection, shared HTTP/Gateway command
  routing, deadline-clamped command auto-defer, redacted deferred-failure
  observation, move-only response capabilities, signed typed component
  dispatch, and install-context visibility policy.
- Add the typed command compiler, deterministic manifest and diff, and the
  guarded `cordnim commands sync` CLI.
- Add distinct Legacy and Components V2 message types, current message fields,
  all current modal fields, BearSSL HMAC routes, and typed migration decoders.
- Add lossless Gateway v10 payload codecs and deterministic session, heartbeat,
  close, shard, identify, and bounded dispatch state machines.
- Add the separate Voice Gateway v8/DAVE package using the official libdave ABI.
- Add ORC Tier 1 CI, schema drift checks, API doc generation, sanitizer fuzz
  targets, and deterministic transport-free tests.
