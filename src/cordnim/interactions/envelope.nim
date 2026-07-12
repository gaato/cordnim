## Trusted-ingress interaction envelope and handler-facing snapshot.
##
## `InteractionEnvelope` is formed once after transport verification. It stores
## typed routing metadata, a redacted copy of the payload, and a narrow post-ACK
## sender. The interaction token is used while that sender is built and is not
## retained as a second field. Handlers never receive the envelope.
##
## `InteractionSnapshot` is the handler-facing projection. It physically contains
## no token and no credential-bearing URL: it carries only typed safe metadata and
## an already-redacted deep copy of the payload. `rawJson` returns an owned copy of
## that redacted tree, so mutating either the original `JsonNode` or a returned
## `rawJson` result can never reach retained authority or a later request URL.

import std/[json, options]

import cordnim/core/[ids, secrets]
import ./[dispatch_core, exchange]

type
  InteractionSenderFactory = proc(applicationId: ApplicationId,
      token: Secret[InteractionToken]): ContextResponseSender
    {.gcsafe, raises: [].} ## Builds one immutable post-acknowledgement sender
    ## from validated credentials. Each envelope invokes the factory once.

  InteractionSnapshot* = object ## Token-free, handler-facing view of one
                                ## interaction. A plain value: copying it can
                                ## never duplicate response authority.
    classValue: InteractionClass
    interactionIdValue: InteractionId
    applicationIdValue: ApplicationId
    guildIdValue: Option[GuildId]
    redacted: JsonNode ## Owned deep copy with the token physically removed.

  InteractionEnvelope = ref object ## Internal, handler-inaccessible ingress state.
    classValue: InteractionClass
    interactionIdValue: InteractionId
    applicationIdValue: ApplicationId
    redacted: JsonNode ## Owned, token-free copy used for all decoding.
    postAckSenderValue: ContextResponseSender

const tokenField = "token"

func redactedCopy(interaction: JsonNode): JsonNode =
  ## Returns an owned deep copy with the top-level interaction token removed.
  ##
  ## Discord embeds the follow-up credential only in the top-level `token`
  ## field; no nested object carries it, and no field carries a pre-signed
  ## credential URL. Removing that single key yields a physically token-free tree.
  if interaction.isNil:
    return newJObject()
  result = interaction.copy()
  if result.kind == JObject and result.hasKey(tokenField):
    result.delete(tokenField)

# --- InteractionSnapshot -----------------------------------------------------

func interactionClass*(snapshot: InteractionSnapshot): InteractionClass =
  ## Returns the transport-independent interaction class.
  snapshot.classValue

func interactionId*(snapshot: InteractionSnapshot): InteractionId =
  ## Returns the typed interaction ID (safe correlation metadata, never secret).
  snapshot.interactionIdValue

func applicationId*(snapshot: InteractionSnapshot): ApplicationId =
  ## Returns the typed application ID.
  snapshot.applicationIdValue

func guildId*(snapshot: InteractionSnapshot): Option[GuildId] =
  ## Returns the guild ID when the interaction ran in a guild.
  snapshot.guildIdValue

proc rawJson*(snapshot: InteractionSnapshot): JsonNode =
  ## Returns an owned, redacted deep copy of the interaction payload.
  ##
  ## The returned tree is freshly copied and physically token-free, so a caller
  ## may freely mutate it without touching the snapshot's own copy or any
  ## retained response authority.
  if snapshot.redacted.isNil:
    newJObject()
  else:
    snapshot.redacted.copy()

func summary(snapshot: InteractionSnapshot): string =
  "InteractionSnapshot(class: " & $snapshot.classValue & ", id: " &
    $snapshot.interactionIdValue & ", application: " &
    $snapshot.applicationIdValue & ")"

func `$`*(snapshot: InteractionSnapshot): string =
  ## Renders typed metadata only; never traverses the payload tree.
  snapshot.summary()

func repr*(snapshot: InteractionSnapshot): string =
  ## Debug rendering that never traverses the payload tree.
  snapshot.summary()

proc `%`*(snapshot: InteractionSnapshot): JsonNode =
  ## Serializes only typed safe metadata; excludes the payload and any token.
  %*{
    "class": $snapshot.classValue,
    "interactionId": $snapshot.interactionIdValue,
    "applicationId": $snapshot.applicationIdValue
  }

proc toJsonHook*(snapshot: InteractionSnapshot): JsonNode =
  ## Redacts snapshots serialized through `std/jsonutils`.
  %snapshot

# --- InteractionEnvelope -----------------------------------------------------

proc buildSnapshot(class: InteractionClass, interactionId: InteractionId,
                   applicationId: ApplicationId,
                   redacted: JsonNode): InteractionSnapshot =
  var guild = none(GuildId)
  if not redacted.isNil and redacted.kind == JObject and
      redacted.hasKey("guild_id") and redacted["guild_id"].kind == JString:
    try:
      guild = some(parseId(GuildId, redacted["guild_id"].getStr()))
    except ValueError:
      guild = none(GuildId)
  InteractionSnapshot(
    classValue: class,
    interactionIdValue: interactionId,
    applicationIdValue: applicationId,
    guildIdValue: guild,
    redacted: redacted)

proc newInteractionEnvelope(interaction: JsonNode, class: InteractionClass,
                             interactionId: InteractionId,
                             applicationId: ApplicationId,
                             token: sink Secret[InteractionToken],
                             senderFactory: InteractionSenderFactory = nil):
                             InteractionEnvelope =
  ## Forms an envelope from already-validated routing identity.
  ##
  ## If `senderFactory` is supplied, the token is passed to it once and is not
  ## retained by the envelope. The resulting sender closes over fixed routing
  ## data, so later JSON mutation cannot redirect a request.
  new result
  result.classValue = class
  result.interactionIdValue = interactionId
  result.applicationIdValue = applicationId
  result.redacted = interaction.redactedCopy()
  if senderFactory != nil:
    result.postAckSenderValue = senderFactory(applicationId, token)

proc parsedIdentity(interaction: JsonNode):
    tuple[id: InteractionId, applicationId: ApplicationId,
          token: Secret[InteractionToken], hasCredentials: bool] =
  ## Best-effort routing-identity extraction that never raises.
  ##
  ## Missing or malformed fields collapse to zero IDs and an empty token; only
  ## when a well-formed application ID and non-empty token are both present does
  ## `hasCredentials` become true, gating whether a post-acknowledgement sender
  ## can be constructed. Decoders raise the real, token-free error later.
  result.id = InteractionId.toId(0'u64)
  result.applicationId = ApplicationId.toId(0'u64)
  result.token = initSecret[InteractionToken]("")
  if interaction.isNil or interaction.kind != JObject:
    return
  let idNode = interaction{"id"}
  if not idNode.isNil and idNode.kind == JString:
    try: result.id = parseId(InteractionId, idNode.getStr())
    except ValueError: discard
  let appNode = interaction{"application_id"}
  var appOk = false
  if not appNode.isNil and appNode.kind == JString:
    try:
      result.applicationId = parseId(ApplicationId, appNode.getStr())
      appOk = result.applicationId.toUint64() != 0
    except ValueError: discard
  let tokenNode = interaction{tokenField}
  var tokenOk = false
  if not tokenNode.isNil and tokenNode.kind == JString and
      tokenNode.getStr().len > 0:
    result.token = initSecret[InteractionToken](tokenNode.getStr())
    tokenOk = true
  result.hasCredentials = appOk and tokenOk

proc looseInteractionEnvelope(interaction: JsonNode,
                               senderFactory: InteractionSenderFactory = nil):
                               InteractionEnvelope {.used.} =
  ## Forms an envelope from a verified payload, tolerating absent identity.
  ##
  ## This is the ingress and convenience path: real Discord payloads always carry
  ## the full identity, so the post-acknowledgement sender is built; reduced
  ## test/harness payloads simply yield an envelope whose sender is `nil` and
  ## whose decoders raise the usual token-free errors. A malformed payload never
  ## surfaces its own token here.
  let identity = interaction.parsedIdentity()
  let factory = if identity.hasCredentials: senderFactory else: nil
  newInteractionEnvelope(interaction, interaction.classify(), identity.id,
    identity.applicationId, identity.token, factory)

func interactionClass(envelope: InteractionEnvelope): InteractionClass {.used.} =
  ## Returns the transport-independent interaction class.
  envelope.classValue

proc decodingJson(envelope: InteractionEnvelope): JsonNode {.used.} =
  ## Returns a fresh token-free copy used by one router decoder.
  ##
  ## Decoded handler values may retain JsonNode fields. Returning a copy keeps
  ## those values from aliasing the envelope or a later snapshot.
  if envelope.isNil or envelope.redacted.isNil:
    newJObject()
  else:
    envelope.redacted.copy()

func postAckSender(envelope: InteractionEnvelope): ContextResponseSender {.used.} =
  ## Returns the preconstructed immutable post-acknowledgement sender, if any.
  envelope.postAckSenderValue

proc snapshot(envelope: InteractionEnvelope): InteractionSnapshot {.used.} =
  ## Builds the handler-facing token-free snapshot for this interaction.
  buildSnapshot(envelope.classValue, envelope.interactionIdValue,
    envelope.applicationIdValue, envelope.redacted.copy())

func observedInteractionId(envelope: InteractionEnvelope):
    Option[InteractionId] {.used.} =
  ## Returns the typed interaction ID as redacted observability correlation.
  some(envelope.interactionIdValue)

func summary(envelope: InteractionEnvelope): string =
  if envelope.isNil:
    "InteractionEnvelope(nil)"
  else:
    "InteractionEnvelope(class: " & $envelope.classValue & ", id: " &
      $envelope.interactionIdValue & ")"

func `$`(envelope: InteractionEnvelope): string {.used.} =
  ## Renders typed metadata only; never the token, sender, or payload tree.
  envelope.summary()

func repr(envelope: InteractionEnvelope): string {.used.} =
  ## Debug rendering that never traverses credentials, the sender, or payload.
  envelope.summary()

proc `%`(envelope: InteractionEnvelope): JsonNode =
  ## Serializes only safe correlation metadata.
  if envelope.isNil:
    newJNull()
  else:
    %*{
      "class": $envelope.classValue,
      "interactionId": $envelope.interactionIdValue,
      "applicationId": $envelope.applicationIdValue
    }

proc toJsonHook(envelope: InteractionEnvelope): JsonNode {.used.} =
  ## Redacts envelopes serialized through `std/jsonutils`.
  %envelope
