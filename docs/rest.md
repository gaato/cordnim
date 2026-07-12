# REST runtime

Cordnim separates generated Discord routes, transport-neutral requests, the
rate-limit scheduler, and the Chronos HTTP implementation. Applications can use
the generated raw inventory without giving generated code control over sockets
or retries.

## Request path

The layers run in this order:

1. A semantic API validates a typed request, or an advanced caller selects a
   generated route directly, then builds `cordnim/raw/request.RawRequest`.
2. `toRuntimeRequest` renders that value into `cordnim/rest.RawRequest` and
   attaches `RequestMeta`.
3. `ChronosRestClient` schedules the request by priority, deadline, route, and
   current Discord bucket state.
4. `DiscordHttpTransport` performs HTTPS, streams the body, reads a bounded
   response, and returns rate-limit metadata.

`RawRequest.$` omits the rendered path, headers, query, and body. A webhook or
interaction token can appear in the path, so logs should use `RouteKey` and a
correlation ID.

## Semantic operations

`cordnim/api` uses the generated routes without exposing generated request
objects as application contracts. Every operation supplies an explicit
`DiscordAuthRequirement`, accepted status set, decoder, and idempotency value.
The shared executor has no default authentication argument, so adding a new
semantic operation without choosing its credential boundary does not compile.

Guild, member, role, channel, thread, message, and management webhook APIs use
bot auth. OAuth identity and current-user entitlement operations use bearer
auth. Webhook-token and interaction callback routes use no authorization header.
See [api.md](api.md) for the operation groups and typed PATCH values.

## Client ownership

`newChronosRestClient` creates a stopped owner. Call `start` before `submit` and
`stop` during shutdown. The client retains its worker and in-flight transport
futures. `stop` cancels and joins active work, fails queued requests with a typed
lifecycle error, and clears scheduler state before a later start.

The concrete HTTP transport owns its Chronos session and pooled connections.
Close the client before closing the transport.

All scheduler mutation belongs to one Chronos event loop. The public types do
not provide cross-thread synchronization.

## Scheduling and rate limits

`RequestMeta.priority` separates interaction acknowledgements, foreground work,
normal requests, and background maintenance. The scheduler chooses the highest
priority eligible request. A future bucket reset cannot block a ready request
from another bucket.

Before Discord returns `X-RateLimit-Bucket`, Cordnim groups requests by their
route template and major parameter. Response headers can remap that provisional
route to Discord's dynamic bucket ID. Global, shared, and user-scoped limits use
monotonic reset instants. Idle bucket retention has a fixed cap.

Deadlines use integer monotonic milliseconds. The Chronos adapter converts its
clock at the boundary and chunks very large sleeps into safe durations.
Cancellation groups let an application cancel queued and in-flight requests by
ID. Repeating a cancellation is safe.

## Retry contract

`RetryPolicy.maxAttempts` includes the first attempt. The first retry waits
`baseDelayMs`, and later retries use capped exponential backoff.

Cordnim retries only when all of these conditions hold:

- the request carries `idSafe`, `idWithNonce`, or `idExplicit` evidence;
- the policy permits the failure category;
- the body can be reproduced for another attempt;
- the request deadline leaves enough time.

Validation, decoding, HTTP protocol, and local stream-state failures remain
terminal. Transient network failures and selected 5xx responses can consume the
bounded retry budget. Non-idempotent follow-up creation uses `idNever` and does
not retry after an ambiguous transport result.

`RetryPolicy.validate` rejects zero attempts, attempts above the fixed cap,
negative delays, and an inverted delay range before work enters the queue.

## Multipart uploads

`AttachmentPlan` distinguishes an existing attachment to keep, metadata to
update or clear, and a new upload. Description and spoiler changes use
`Patch[T]`, so omit, JSON null, and a concrete value remain distinct.

An `UploadSource` opens a fresh `UploadCursor` for each attempt. The cursor reads
bounded chunks and closes once. File and memory sources are replayable.
A custom source must declare whether it can open another cursor.

`initMultipartBody` freezes `payload_json`, attachment metadata, upload order,
filenames, and source factories. A known total size uses exact
`Content-Length`. An unknown source size uses chunked transfer encoding. The
transport treats a declared-length mismatch as a terminal framing error.

Source callbacks may opt into retry by raising Cordnim's typed transport error.
Other source failures become redacted terminal validation errors. Writer I/O
retains its transient transport category. Cleanup never replaces the primary
failure.

## Errors

Public REST failures use `DiscordError` categories:

- validation and lifecycle errors describe caller or owner state;
- cancellation and deadline errors describe request termination;
- transport errors may be retryable when idempotency permits it;
- decode and HTTP errors describe terminal response or protocol failures;
- Discord API errors contain safe status and code metadata without response
  bodies or token-bearing URLs.

Catch the exported subtype or inspect `DiscordError.kind` instead of matching an
exception message.

## Chronos 4.2 TLS limitation

Chronos 4.2 reports some initial TLS protocol and handshake failures with the
same `HttpConnectionError` used for transient connection failures. Cordnim
cannot distinguish those cases at its boundary. An idempotent request may spend
its bounded transport retry budget on that class. TLS protocol errors that
Chronos exposes as a distinct type remain terminal.

External API origins require HTTPS. Plain HTTP is accepted only for loopback
test servers. Base URLs with user information, a query, or a fragment fail
during construction.

Discord's [Rate Limits](https://docs.discord.com/developers/topics/rate-limits)
and [API Reference](https://docs.discord.com/developers/reference) define the
wire behavior.
