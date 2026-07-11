# Architecture

cordnim deliberately separates protocol completeness from application comfort.

## Layers

`cordnim/raw` mirrors Discord's wire contract. It preserves unknown enum values,
flag bits, and fields and exposes every pinned stable HTTP route. A generic raw
request is available when Discord ships a field before cordnim's next release.

The runtime layer owns all I/O policy: REST buckets and retries, interaction
acknowledgement deadlines, Gateway sessions and shards, cache policy, structured
task lifetimes, and Voice transport. Application handlers do not implement their
own rate limit or reconnection loops.

`cordnim/app` is the high-level entry point. It combines explicit command sets,
Components V2, forms, typed services, middleware, observability, and test
drivers. Dropping to a lower layer is always explicit and supported.

## Interaction ingress

Discord delivers interactions to an application through one configured ingress:
HTTP outgoing webhooks or the Gateway. `InteractionIngress` models that choice.
Other Gateway subscriptions remain independent, so an HTTP interaction app can
still consume Guild, Voice, or Message events.

## Compatibility

The high-level package follows Semantic Versioning. Raw schema updates publish a
separate `discordSchemaRevision`; additive Discord fields and unknown values do
not require a high-level major release. Preview protocol shapes require an
explicit import.

## Ownership

Resource owners such as upload streams, Voice packets, and session leases use
destructors and sink parameters at synchronous boundaries. Interaction response
correctness does not rely on a value remaining move-only across `await`; an
atomic runtime state machine is the final authority.

## Current alpha boundary

The Gateway modules currently implement typed Gateway v10 JSON payload codecs
and deterministic protocol and supervision state. They do not yet open a
WebSocket. This lets payload round trips, resume, close-code, heartbeat,
IDENTIFY-budget, queue, and shard rules be tested without making an unfinished
transport look production-ready.

Command routing decodes user and message context-menu targets into typed
snowflakes. Persistent component interactions have a typed, versioned, signed
router that can recover actions after a process restart. Component auto-defer,
autocomplete routing, and modal-submit orchestration are not yet complete.

The optional Voice package follows the same boundary. Voice Gateway v8 payloads,
DAVE transitions, and the official libdave C ABI are present. UDP, Opus, jitter,
mixing, and media scheduling remain separate work. No DAVE cryptography is
implemented in Nim.

The REST transport is operational for JSON requests. `UploadStream` and
attachment edit planning already enforce move-only ownership and bounded reads;
the Chronos multipart writer that connects those streams to HTTP is not complete.
