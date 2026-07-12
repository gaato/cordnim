# Architecture

Cordnim is an application runtime and declaration compiler, not a thin set of
Discord HTTP wrappers. It separates application policy, asynchronous runtime
ownership, and generated wire declarations so a schema update does not silently
change handler behavior.

Importing a module creates values only. It does not open a socket, start a task,
register a command, or read a credential.

## Public layers

The public surfaces have different stability and ownership roles:

- `cordnim` is the application facade. It exports application composition,
  commands, components, core protocol values, build identity, and the HTTP
  interaction runtime factory.
- `cordnim/interactions` owns transport-independent interaction dispatch,
  response authority, HTTP verification, persistent routes, and HTTP/Gateway
  delivery adapters.
- `cordnim/rest` owns request scheduling, dynamic Discord rate limits,
  replayable bodies, deadlines, retries, and Chronos HTTP connections.
- `cordnim/gateway` owns Gateway v10 transport, compression, sessions,
  coordination, shard runners, dispatch, supervision, and entity caching.
- `cordnim/raw` is generated from the pinned Discord HTTP schema and semantic
  overlay. It exposes wire objects and route constructors without performing
  I/O.

`cordnim/cache`, `cordnim/observability`, and `cordnim/testing` are explicit
support surfaces. Generated wire names and runtime control types stay out of the
main facade unless application handlers need them directly.

## Application ownership

`DiscordApp[S]` owns one service allocation, a command registry, middleware, and
an ordered list of runtime components. `CommandCtx[S]`, `ComponentCtx[S]`, and
`ModalCtx[S]` borrow that same service allocation. A context copy does not copy
`S` or create another response right.

Runtime factories attach complete start, wait, and close operations while the
application is `alsReady`. `run` starts components in attachment order. Shutdown
cancels and joins application work, then closes components in reverse order.
Concurrent lifecycle callers share the owned operation rather than starting a
second transport.

`AppConfig` separates interaction ingress from Gateway event subscriptions:

- `ingressHttp` without Gateway events is webhook-only;
- `ingressHttp` with Gateway events is hybrid;
- `ingressGateway` uses the Gateway for interactions and may also subscribe to
  other events.

This distinction prevents an application from treating interaction delivery and
event subscription as the same setting.

## Interaction protocol

`InteractionDispatcher[S]` is the common application boundary for HTTP and
Gateway ingress. It classifies pings, commands, autocomplete, message
components, and modal submissions, then routes them through one response model.
Only the final delivery adapter differs.

`InteractionExchange` separates response selection from transport delivery. A
handler, fallback, or auto-defer selects one immutable callback body. HTTP
confirms the selection after the response write; Gateway confirms it after its
callback request succeeds. A failed or cancelled send marks delivery unknown.

Post-response edits and follow-ups wait for that delivery receipt. The ingress
receives a narrow confirm-or-unknown capability, not the exchange itself, so it
cannot select a replacement response. Cancellation of one waiter cannot cancel
the shared receipt.

Response rules depend on interaction origin. A component-origin modal submit can
update its source message. A command-origin modal submit has no source message
and cannot use update callback types. Typed `ModalSpec` values are validated on
the standard path; raw JSON requires an explicitly named escape hatch.

The dispatcher owns retained handler tails and seals registration when close
starts. Handler exceptions cross the application boundary only as stable
categories and correlation IDs. See [interactions.md](interactions.md) for the
delivery and deadline contract.

## Commands and components

Command macros compile procedures into `CommandSpec`, handler adapters, and
deterministic manifests. They do not perform registration I/O. Explicit builders
remain available for nested subcommand groups, localizations, choices, and
autocomplete schemas.

Autocomplete handlers are addressed by the full command, group, subcommand, and
option path. This allows two subcommands to reuse an option name without sharing
a handler accidentally.

Legacy message components and Components V2 use different draft types. The type
parameter prevents a builder from combining layouts that Discord treats as
different message modes. Modal forms have their own root constraints and do not
reuse the Components V2 message-node limit.

Persistent component and modal routes contain a versioned, expiring, signed
envelope. Applications own the key store and migration lifetime. A route can
survive restart when the next process has the required verification key and
decoder.

## REST and raw HTTP

Generated raw routes build values. `toRuntimeRequest` renders those values and
attaches scheduler metadata. `ChronosRestClient` then applies priority,
deadlines, cancellation groups, learned bucket IDs, global limits, and bounded
retry policy before `DiscordHttpTransport` performs I/O.

Retry requires explicit idempotency evidence and a reproducible body. Multipart
requests retain fresh-cursor source factories rather than open handles. Each
attempt owns and closes its cursor, and the request constructor freezes upload
ordering and JSON metadata before scheduling.

Checked REST errors omit rendered token-bearing paths, response bodies, and
credential headers. The scheduler works with route templates and major
parameters rather than secret webhook URLs.

The raw layer comes from a pinned Discord HTTP v10 OpenAPI document plus a
reviewed semantic overlay. Generated objects preserve unknown JSON fields, open
enum values, and unnamed flag bits. Overlay selectors are match-counted so a
schema movement cannot silently apply a correction to the wrong field. See
[raw-schema.md](raw-schema.md) for the generation boundary.

## Gateway ownership

`GatewayShardRunner` is the asynchronous owner of one shard. It acquires a
fenced lease, reads resumable session state, connects a canonical Gateway URL,
waits for HELLO, starts jittered heartbeats, chooses IDENTIFY or RESUME, decodes
messages, and reconnects according to close and session state.

The connection owns one reader and one per-connection decoder. `zlib-stream`
uses a persistent native inflate context across WebSocket messages and releases
it exactly once. Compressed and inflated data have separate bounds.

The runner owns its dispatch runtime. A dispatch sequence is recorded only after
the bounded queue admits the event. If the queue is full, the runner aborts and
resumes from the last admitted sequence. It never drops the event, advances past
it, or blocks the WebSocket reader on an unbounded handler wait.

`GatewayRuntime` supervises a shard plan. The default is fail-fast: a terminal
shard failure closes the other shards and returns redacted failure metadata. An
optional restart budget is finite and per shard.

The coordination interface is distributed-shaped. Shard leases carry fencing
tokens; renew, release, session read, and session write reject stale owners.
IDENTIFY reservations are non-refundable. Backend operations return relative
durations so application and backend wall clocks are not compared. Cordnim ships
a deterministic process-local adapter; a multi-process deployment supplies a
backend adapter with the same contract.

## Dispatch and cache

Gateway dispatch supports ordered, guild-partitioned, and bounded concurrent
policies. Each worker owns admitted events until its handler completes. Close
cancels and joins workers and queued work.

`EntityCache` can retain guilds, channels and threads, members, presences, and
messages under separate disabled, full, LRU, or TTL policies. It applies create,
update, delete, bulk, and synchronization events before delivering the raw event
to the application handler. Cache failures are observable but do not suppress
raw delivery.

Entries are serialized semantic JSON snapshots. Each lookup parses a fresh
`JsonNode`, so a caller cannot mutate the cache through an alias. Guild and
channel deletion cascades operate even when the parent entity class itself is
disabled.

`EntityResolver[K, V]` is a separate cache/REST composition. `cacheOnly` never
performs I/O, `restOnly` always performs it, and `cacheThenRest` fetches only on
a miss. This keeps a lookup call from hiding network behavior.

`Collector[T]` is a bounded, process-local queue for a short interaction flow.
It is not durable component routing or an entity cache.

## Event-loop and error boundary

Runtime owners are confined to one Chronos event loop. Their public types do not
provide cross-thread synchronization. Callbacks marked `gcsafe` can be retained
by Chronos, but that annotation does not make a mutable runtime safe to share
between OS threads.

Errors are translated at ownership boundaries. Stable categories, codes,
correlation IDs, shard IDs, and route templates may reach logs or metrics.
Handler messages, coordination backend messages, credentials, rendered webhook
paths, and payload bodies do not.

## Voice boundary

The separate `cordnim_voice` package contains Voice Gateway v8 codecs, DAVE
state, and an opt-in binding to the official `libdave` C API. It does not own UDP
media transport, Opus encoding or decoding, a jitter buffer, a mixer, or a media
scheduler.

## Compatibility identity

The public release version has not been assigned. `CordnimBuildLabel` identifies
a concrete build for diagnostics without turning the Nimble packaging
placeholder into an API promise.

Generated raw declarations carry `discordSchemaRevision`, the source commit,
schema digest, and overlay revision. Applications that persist raw payloads
should record both the Cordnim build identity and Discord schema identity.
