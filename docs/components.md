# Components and modal forms

Cordnim keeps legacy message components, Components V2 messages, modal forms,
restart-safe routes, and short-lived collectors as separate concepts. Each one
has a different wire contract and lifetime.

## Legacy and Components V2 messages

`MessageDraft[Legacy]` models legacy content, embeds, and action rows.
`MessageDraft[V2]` models the Components V2 tree. The type parameter prevents a
caller from mixing the two layouts in one builder.

```nim
import cordnim/components

let draft = v2Message:
  container:
    text "## Deployment"
    section:
      text "Choose the next action."
      thumbnail "https://example.invalid/icon.png"
    actions:
      button "Deploy", "deploy:confirm"
      button "Cancel", "deploy:cancel"

doAssert draft.validate().valid
let body = draft.toJson()
```

Builders create values only. Call `validate` before sending a draft assembled
from runtime data. Validation checks nesting, cycles, node counts, field
placement, button targets, select constraints, and character limits. Serialization
adds an empty `allowed_mentions.parse` policy unless the caller supplied one.

Components V2 messages have a total component-node limit. Modal callbacks use a
different root limit and must not reuse the message-tree count.

Premium buttons contain a SKU target. Discord does not permit a label, emoji,
custom ID, or URL on that button style. Link buttons use a URL and no custom ID.
Interactive buttons use a custom ID and no URL.

## Typed modal forms

`deriveDiscordModal` generates a schema and submission decoder from a Nim
object. Current modal fields include text input, string and entity selects, file
upload, radio group, checkbox group, and checkbox. A modal root contains labels
and text displays in wire order.

```nim
type ReviewForm {.discordModal(
    title = "Review deployment",
    customId = "review"
).} = object
  note {.textInput(
    label = "Note",
    minLength = 1,
    maxLength = 400
  ).}: string

deriveDiscordModal(ReviewForm)

let spec = modalSpec(ReviewForm)
doAssert spec.validate().len == 0
```

The standard interaction `showModal` path accepts `ModalSpec` and validates it
before selecting callback type 9. `showRawModal` is the explicit escape hatch
for a caller that already owns a raw Discord modal object.

Submission decoding returns `ModalDecodeResult[T]`. It collects field problems
instead of failing at the first invalid value. Unknown submitted fields remain
available in their wire order, which lets an application roll out a new form
without making an older process discard the submission.

Component IDs and custom IDs serve different purposes. Component IDs are
optional numeric identifiers assigned within a component tree. Custom IDs are
developer-defined strings used to route interactions.

## Persistent routes

`RouteCodec` signs a compact route envelope containing a key ID, route type,
version, expiry, and payload. `TypedRouteCodec[T]` supplies the active encoder
and versioned migration decoders for one action type.

The application owns signing-key storage and rotation. Keep the active signing
key plus old verification keys for the longest route lifetime. A process can
dispatch an old message after restart when it has the same key ring and a
decoder for the route version.

`ComponentRouter` authenticates the envelope before it invokes a typed handler.
`ModalRouter` applies the same rule to the modal root custom ID before it decodes
submitted fields. Handler errors cross both boundaries as stable redacted
errors.

`routedModalSpec` replaces the modal root custom ID with a signed route and
returns a validated `ModalSpec` for the normal `showModal` path. It raises before
selection when the signed ID or another schema field violates Discord's limit.
`routedModalJson` is the corresponding low-level value for `showRawModal` when a
caller deliberately owns the raw JSON boundary.

## Collectors

`Collector[T]` is an in-process bounded queue for short-lived workflows. It can
filter events, enforce a deadline, and stop after a maximum number of matches.
Close releases queued items and wakes waiters.

Collectors do not make a component restart-safe. Use a signed typed route for a
button or modal that must survive deployment or process failure. A handler may
start a collector after it receives a persistent route when the next few events
belong to the current process.

## Ownership and raw JSON

Component drafts and modal specs are value schemas. Interaction routers own
their retained handler tasks and close them with the dispatcher. They run on one
Chronos event loop unless the application adds its own synchronization.

Raw `JsonNode` escape hatches transfer semantic ownership to the caller. Freeze
or copy a node before sharing it with another task. The interaction exchange
takes its own snapshot when a response is selected.

See Discord's [Component Reference](https://docs.discord.com/developers/components/reference)
for current field availability and callback restrictions.
