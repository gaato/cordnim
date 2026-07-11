# Security model

Applications control credentials, signing keys, public bind addresses, TLS
termination, and logs. cordnim enforces the protocol checks described below.

## HTTP interactions

`InteractionHttpServer` requires an `Ed25519Verifier`. It limits the body while
Chronos reads it, then checks timestamp skew, the detached signature, and the
replay cache before dispatch. A full replay cache rejects new requests until an
entry ages out. Size it for the highest accepted request count within the skew
window.

The optional libsodium adapter requires `-d:cordnimSodium`. Builds without that
define return `false` from the adapter. `parseEd25519PublicKey` accepts the
64-character hexadecimal key from Discord's application settings.

Bind the interaction listener to loopback when a reverse proxy or tunnel owns
the public endpoint. Review proxy body limits and make sure it forwards
`X-Signature-Ed25519` and `X-Signature-Timestamp` without modification.

## Initial response delivery

The router consumes the initial response right when a handler or auto-defer
selects a body. The exchange keeps that claim pending until the ingress confirms
delivery.

For HTTP, `InteractionHttpServer` confirms after the Chronos response write
succeeds. A write error or cancellation marks the state
`irTransportUnknown`. The router does not send a second initial response from
that state.

Post-acknowledgement edits and follow-ups wait for the delivery receipt. This
ordering prevents a webhook PATCH or POST from reaching Discord before the
initial acknowledgement.

User-installed applications may have a five-message follow-up limit. The
exchange reserves a slot before each POST and keeps it after an ambiguous
transport result. The webhook scheduler disables automatic retries for
follow-up POSTs to avoid duplicate messages. Original-message PATCH requests
carry explicit idempotency evidence.

## Credentials and diagnostics

Use `Secret[BotToken]`, `Secret[InteractionToken]`, and
`Secret[WebhookToken]` at credential boundaries. Their string, representation,
and JSON renderers return `[REDACTED]`. `reveal` copies the value for a protocol
call; keep that copy out of logs and long-lived objects.

Webhook and interaction tokens appear in URL paths. `RawRequest.$` omits
rendered paths, query values, headers, and bodies. The REST scheduler uses route
keys without token values. Application logs should omit raw request paths,
request bodies, authorization headers, signatures, and handler exception text.

The Discord HTTP transport accepts external origins only over HTTPS. Plain HTTP
is limited to `localhost`, `127.0.0.1`, and `::1` for tests. Base URLs with
credentials, queries, or fragments fail during construction.

The CLI parses `.env` as key/value text and does not execute it. Git ignores
`.env` files except for `.env.example`. Use mode `0600` on a multi-user Unix
host.

## Gateway transport

Status `websock` owns the RFC 6455 handshake, TLS, masking, framing, control
frames, and fragmentation. Cordnim caps the complete message after fragment
assembly and rejects invalid UTF-8 close reasons.

The pinned `websock` source misparses close payloads. Cordnim applies the
tracked replacement described in `vendor/patches/websock/README.md`. It also
keeps internal sentinel 1005 off the wire and rejects forbidden peer code 1015.
A missed Discord 4014 close would turn a terminal configuration error into a
reconnect loop, so releases must run the wire tests before changing that pin or
removing the replacement.

`GatewayTransport` assigns one reader to the WebSocket and retains active send
operations. Shutdown cancels and joins active I/O before starting the close
path. Cancellation aborts the connection when a graceful handshake would make
an in-flight message's delivery ambiguous.

## Components and route signatures

Message and component response encoders add an empty
`allowed_mentions.parse` list unless the caller supplies a policy. Discord
remains the authority for channel and member permissions.

Component validation rejects cyclic trees before counting or serializing them.
Persistent route identifiers carry a version, expiry, key identifier, and
truncated HMAC-SHA-256 tag. Keep signing keys outside source control and retain
old verification keys only for the planned rotation window.

## Unsupported credentials

The bot REST transport constructs `Authorization: Bot ...` from a typed token.
The interaction webhook transport sends no authorization header because
Discord authenticates the token in the path. User tokens and self-bot operation
are outside the supported API.
