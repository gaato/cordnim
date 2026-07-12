## Semantic model for the Discord webhook resource.

import std/[json, options]

import ./common
import ./user
import ../core/secrets

export common
export user
export secrets

type
  WebhookUrlKind* = object ## Type marker for a webhook's credentialed URL.
    ## The URL embeds the webhook token, so it is as sensitive as the token
    ## itself and is wrapped in a `Secret`.

  WebhookType* = enum ## Discord webhook kinds.
    wtIncoming = 1 ## Posts messages via a token.
    wtChannelFollower = 2 ## Reposts messages from a followed channel.
    wtApplication = 3 ## Created for an interaction application.

  Webhook* = object ## A decoded Discord webhook.
    id*: WebhookId ## Unique snowflake identity of the webhook.
    kind*: OpenEnum[WebhookType, int] ## Webhook kind.
    guildId*: Option[GuildId] ## Guild the webhook belongs to, when any.
    channelId*: Option[ChannelId] ## Channel the webhook posts to; required but
                                  ## nullable across all response variants.
    user*: Option[User] ## Creator of the webhook, when Discord sent it.
    name*: Option[string] ## Default name of the webhook; required and non-null
                          ## for known webhook types.
    avatar*: Option[string] ## Default avatar hash; required but nullable.
    token*: Option[Secret[WebhookToken]] ## Secret token, for incoming
                                         ## webhooks the caller may use.
    applicationId*: Option[ApplicationId] ## Application that created the
                                          ## webhook; required but nullable.
    url*: Option[Secret[WebhookUrlKind]] ## Full webhook URL, wrapped as a
                                         ## secret because it embeds the token.
    snapshot: DiscordSnapshot ## Retained decode evidence for the webhook.

proc decodeWebhook*(node: JsonNode): Webhook =
  ## Decodes a full Discord webhook object, rejecting missing required fields.
  let obj = ensureObject(node, "webhook")
  result.id = decodeId(WebhookId,
    requireField(obj, "id", "webhook"), "webhook.id")
  result.kind = decodeIntEnum(WebhookType,
    requireField(obj, "type", "webhook"), "webhook.type")
  # The three known webhook response variants share one required-key list.
  # An unknown `type` only guarantees `id` and `type`, so nothing more is
  # enforced for it.
  if result.kind.knownValue.isSome:
    result.name = some(
      asString(requireField(obj, "name", "webhook"), "webhook.name"))
    result.avatar = reqNullableString(obj, "avatar", "webhook")
    result.channelId = reqNullableId(ChannelId, obj, "channel_id", "webhook")
    result.applicationId = reqNullableId(
      ApplicationId, obj, "application_id", "webhook")
  else:
    result.name = optString(obj, "name", "webhook")
    result.avatar = optString(obj, "avatar", "webhook")
    result.channelId = optId(ChannelId, obj, "channel_id", "webhook")
    result.applicationId = optId(ApplicationId, obj, "application_id", "webhook")
  result.guildId = optId(GuildId, obj, "guild_id", "webhook")
  let user = optionalField(obj, "user")
  if user.isSome:
    result.user = some(decodeUser(user.get))
  let token = optionalField(obj, "token")
  if token.isSome:
    result.token = some(
      initSecret[WebhookToken](asString(token.get, "webhook.token")))
  let url = optionalField(obj, "url")
  if url.isSome:
    result.url = some(
      initSecret[WebhookUrlKind](asString(url.get, "webhook.url")))
  # Scrub the credential-bearing `token` and `url` before they enter the
  # snapshot, so no generic representation of a `Webhook` (`repr`, `rawJson`,
  # `unknownFields`, or a plain copy) can reveal them. The plaintext survives
  # only inside the `token` and `url` `Secret` fields, which redact themselves.
  var scrubbed = obj
  if scrubbed.hasKey("token") or scrubbed.hasKey("url"):
    scrubbed = obj.copy()
    if scrubbed.hasKey("token"):
      scrubbed["token"] = newJString(redactedSecret)
    if scrubbed.hasKey("url"):
      scrubbed["url"] = newJString(redactedSecret)
  result.snapshot = initSnapshot(scrubbed, [
    "id", "type", "guild_id", "channel_id", "user", "name", "avatar", "token",
    "application_id", "url"])

proc parseWebhook*(text: string): Webhook =
  ## Decodes a Discord webhook from a JSON document string.
  decodeWebhook(parseJsonObject(text, "webhook"))

proc rawJson*(webhook: Webhook): JsonNode =
  ## Returns a safe deep-copied snapshot of the webhook's original JSON.
  ##
  ## The retained snapshot is stored with `token` and `url` already replaced by
  ## `redactedSecret`, so this deep copy carries no credential bytes; the
  ## plaintext lives only in the `token` and `url` `Secret` fields. All other
  ## fields, including any unknown ones, round-trip unchanged.
  rawJson(webhook.snapshot)

proc unknownFields*(webhook: Webhook): seq[UnknownField] =
  ## Returns deep copies of webhook fields not consumed by the decoder.
  unknownFields(webhook.snapshot)
