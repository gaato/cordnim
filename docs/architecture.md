# Architecture

cordnim separates application code, interaction delivery, REST scheduling, and
Discord wire declarations. Importing a module does not open a socket or start a
task.

## Public facade

The main `cordnim` module exports:

- typed identifiers, permissions, optional fields, open values, and redacted
  secrets;
- application composition, command declarations, middleware, and manifests;
- component builders, validation, forms, and signed route codecs;
- HTTP verification configuration and the webhook-only runtime factory.

Use explicit imports for `cordnim/interactions`, `cordnim/rest`,
`cordnim/gateway`, and `cordnim/raw`. This keeps responder internals, scheduler
controls, and generated wire names out of application handlers.

## Application ownership

`DiscordApp[S]` owns one allocation containing the service value, plus the
command registry, middleware chain, and transport lifecycle. Middleware gets a
reference to that allocation. `CommandCtx[S]` keeps the same reference and
borrows its value through `ctx.services`; it does not copy `S`. The response
context contains only the interaction exchange.

The app stores one task for startup, waiting, and shutdown. Concurrent callers
share those tasks. Shutdown cancels and joins startup or wait work before it
calls the close hook. A failed close leaves the app in `alsClosing`; another
`close` call retries the idempotent hook.

`AppConfig` chooses one interaction ingress. `CommandRouter.asHttpHandler`
accepts `ingressHttp`, while `routeGateway` accepts `ingressGateway`. Gateway
event subscriptions remain a separate setting. The webhook-only runtime rejects
hybrid configurations because it cannot own the missing Gateway event session.

## Interaction exchange

`InteractionExchange` owns the atomic responder, selected initial response,
delivery receipt, post-acknowledgement port, and follow-up budget for one
interaction.

HTTP requires two phases:

1. A handler, result fallback, or auto-defer claims the responder and selects
   the callback body.
2. `InteractionHttpServer` commits the claim after Chronos completes the socket
   write. A failed or cancelled write marks delivery unknown.

`ctx.editOriginal` and `ctx.followup` wait for phase 2. A user-install follow-up
reservation uses an atomic counter. The exchange keeps the reservation after an
ambiguous POST because restoring it could exceed Discord's limit.

Gateway interaction ingress uses the same exchange. The callback sender
confirms delivery after its REST request succeeds.

Command handlers may return `CommandResult` or select a response through
`CommandCtx`. A selected context response owns wire output. Router-generated
auto-defer continues to use the returned result for the original-message edit.

## Webhook-only runtime

`newInteractionHttpRuntime` binds these resources to one app lifecycle:

- the verified Chronos interaction server;
- a command router and its background task scope;
- a webhook REST scheduler and HTTP connection pool.

The runtime starts the REST worker before accepting requests. Shutdown closes
the listener, joins router tasks, stops REST work, and closes pooled
connections.

## REST and raw HTTP

`cordnim/rest` provides one Chronos scheduler for Discord buckets, priorities,
deadlines, cancellation groups, and retry policy. The HTTP transport requires
HTTPS for external origins and permits plain HTTP only for loopback tests.
Checked helpers convert non-2xx replies into typed errors without placing
response bodies or token-bearing URLs in diagnostics.

`cordnim/raw` comes from a pinned Discord HTTP v10 snapshot. Generated objects
retain unknown fields, enum values, and flag bits. Route metadata and the generic
request constructor cover operations that lack a high-level wrapper.

The multipart module models bounded upload streams and attachment plans. The
0.1 HTTP transport does not write multipart bodies.

## Gateway boundary

`cordnim/gateway` includes an injectable transport contract and a Chronos
adapter over Status `websock`. The adapter preserves text and binary messages,
fragmented-message bounds, cancellation, TLS hostname verification, and exact
close code and reason data.

The pinned `websock` 0.4 source has close-frame parsing defects. `config.nims`
replaces that one module with the MIT-licensed copy under
`vendor/patches/websock/`. Wire tests cover Discord close codes, UTF-8 reasons,
empty close payloads, forbidden code 1015, and a close control frame inserted
inside a fragmented text message. Remove the replacement after Atlas pins an
upstream release with the same fixes.

`GatewayTransport` permits one active receive and owns all active sends.
`closeWait` cancels and joins active I/O before the driver can start a close
handshake. A send-close race aborts the connection, so a queued or partially
written message cannot report successful delivery.

Payload codecs and state machines cover HELLO, heartbeat, IDENTIFY, RESUME,
session cursors, close policy, identify budgets, shard plans, and dispatch
queues. The 0.1 package has no owner that joins those pieces into a running
shard loop.

## Voice boundary

The separate `cordnim_voice` package contains Voice Gateway v8 codecs, DAVE
state, and an optional binding to the official `libdave` C API. It has no UDP
transport, Opus pipeline, jitter buffer, mixer, or media scheduler.

## Compatibility

The package version tracks the application API. Generated raw declarations
carry `discordSchemaRevision`, which records the pinned Discord specification
snapshot. Applications that use raw declarations should record both values in
their compatibility checks.
