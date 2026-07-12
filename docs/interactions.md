# Interaction runtime

Cordnim treats a Discord interaction as one transport-independent application
protocol. HTTP and Gateway ingress use the same classifier, dispatcher,
response authority, handler deadlines, persistent routes, and post-response
transport port.

## One dispatcher

`InteractionDispatcher[S]` classifies ping, command, autocomplete, message
component, and modal-submit payloads. It owns the command router and the task
scopes that retain handler tails. Optional component and modal routers share one
signed `RouteCodec`.

HTTP converts the selected callback into the response body of the verified
request. Gateway sends the same callback through an application-provided
callback sender. The adapters differ only in delivery. A handler cannot select a
different response based on which ingress carried the interaction.

Register persistent handlers before the owning application starts:

```nim
let runtime = newInteractionHttpRuntime(
  app,
  bindAddress,
  verification,
  routeEnvelope = some(routeCodec)
)

runtime.dispatcher.registerComponent(buttonCodec, handleButton)
runtime.dispatcher.registerModal(formCodec, handleForm)
runtime.dispatcher.registerAutocomplete(
  initCommandKey(ckChatInput, "search"),
  "query",
  completeQuery
)
```

Registration and dispatch are sealed when dispatcher shutdown starts. `close`
cancels and joins retained work before returning.

Gateway applications obtain the same dispatcher from the high-level bot
runtime:

```nim
let bot = newGatewayBotRuntime(
  app, token, singleProcessGateway(),
  routeEnvelope = some(routeCodec)
)

bot.interactions.registerComponent(buttonCodec, handleButton)
bot.interactions.registerModal(formCodec, handleForm)
bot.interactions.registerAutocomplete(
  initCommandKey(ckChatInput, "search"), "query", completeQuery)
```

The runtime sends the initial callback through its owned REST client. The shard
runner keeps interaction payloads out of the generic `DispatchEvent` feed and
runs them on an independent bounded worker set.

## HTTP verification

`InteractionHttpServer` reads a bounded body, checks timestamp skew, verifies
the Ed25519 signature over `timestamp || body`, and records the signature in a
bounded replay cache before dispatch. Invalid requests do not reach application
handlers.

The libsodium adapter is opt-in:

```fish
nim c --mm:orc -d:cordnimSodium src/bot.nim
```

Builds without that define do not silently substitute another verifier. Supply
an application-owned `Ed25519Verifier` or enable the adapter deliberately.

When a reverse proxy terminates public TLS, bind the Chronos listener to a
loopback address and preserve Discord's signature and timestamp headers without
modification. Apply a proxy body limit no larger than the application intends to
accept.

## Selection and delivery

An `InteractionExchange` separates two events:

1. A handler, result fallback, or auto-defer selects one initial response.
2. The ingress adapter confirms that Discord received the selected callback, or
   marks the result unknown.

Selection freezes the response JSON. Later mutation of a caller-held alias
cannot change the chosen callback. The adapter receives a narrow
`InitialDeliveryAuthority`; it can confirm or mark delivery unknown, but it
cannot select another response.

`editOriginal` and `followup` wait for the delivery receipt. Cancelling one
waiter cannot cancel the shared receipt. If the socket or Gateway send has an
ambiguous outcome, Cordnim seals the exchange and does not attempt a second
initial response.

User-installed interactions can carry a five-follow-up budget. A follow-up
reserves one slot before transport I/O and keeps it after an ambiguous result.
Restoring the slot could let the application exceed Discord's limit.

## Deadlines and auto-defer

The responder records receipt time with a monotonic clock. Command,
autocomplete, component, and modal handling reserve a send margin before the
acknowledgement deadline. The runtime races handler completion, response
selection, and that deadline, then cancels and joins the losing futures.

`manualAck` requires the handler to select the response. `autoDefer` schedules a
deferred message response; `autoDeferUpdate` is available only where the
interaction can update a source message. A command-origin modal submission has
no source message and cannot use deferred-update or update-message callback
types.

Autocomplete has its own response action and callback shape. It cannot claim a
message or modal response state. Handler failures are reduced to a redacted
correlation ID before they cross the dispatcher boundary.

## Response contexts

`CommandCtx[S]`, `ComponentCtx[S]`, and `ModalCtx[S]` borrow the same service
allocation owned by `DiscordApp[S]`. Their response methods use the exchange's
single authority:

- `reply` and `deferReply` select an initial message response;
- `deferUpdate` and `updateMessage` apply only to a component-origin response;
- `showModal` accepts and validates a `ModalSpec`;
- `showRawModal` is the explicit raw JSON escape hatch;
- `editOriginal` and `followup` wait for confirmed initial delivery.

A returned `CommandResult` remains useful to middleware. Once the context has
selected a response, that selected response controls the wire output.

## Persistent routes and form submission

Component and modal route envelopes contain a route type, version, expiry, key
identifier, payload, and HMAC tag. Authentication and migration happen before a
typed handler runs. Route expiry uses an injectable Unix-seconds clock because
the identifier can survive process restart.

`ModalRouter` distinguishes a submission attached to an existing message from a
command-origin submission. This origin controls which initial callback types are
legal. The typed form decoder reports all field problems and retains unknown
submitted fields for rolling deployments.

See [commands.md](commands.md) for command schemas and autocomplete paths, and
[components.md](components.md) for Components V2, modal schemas, and route-key
rotation.

Discord's [Receiving and Responding documentation](https://docs.discord.com/developers/interactions/receiving-and-responding)
defines the current callback types and delivery deadlines.
