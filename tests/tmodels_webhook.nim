## Focused tests for the semantic webhook model.

import std/[json, options, strutils]

import cordnim/models/webhook

const webhookUrl =
  "https://discord.com/api/webhooks/223704706495545344/supersecrettoken"

# A complete GuildIncomingWebhookResponse.
proc completeWebhook(): JsonNode =
  %*{
    "id": "223704706495545344",
    "type": 1,
    "channel_id": "199737254929760256",
    "guild_id": "199737254929760255",
    "name": "test webhook",
    "avatar": newJNull(),
    "token": "supersecrettoken",
    "application_id": newJNull(),
    "url": webhookUrl,
    "user": {"id": "1", "username": "creator", "discriminator": "0",
             "global_name": newJNull(), "avatar": newJNull(),
             "public_flags": 0, "flags": 0, "primary_guild": newJNull()}}

block decodesIncomingWebhookWithRedactedCredentials:
  let webhook = decodeWebhook(completeWebhook())
  doAssert webhook.id.toUint64 == 223704706495545344'u64
  doAssert webhook.kind.knownValue == some(wtIncoming)
  doAssert webhook.channelId.isSome
  doAssert webhook.name == some("test webhook")
  doAssert webhook.avatar.isNone
  doAssert webhook.applicationId.isNone
  doAssert webhook.user.isSome
  # The token reveals its value explicitly but redacts in string form.
  doAssert webhook.token.isSome
  doAssert webhook.token.get.reveal == "supersecrettoken"
  doAssert $webhook.token.get == "[REDACTED]"
  # The url is modelled as a secret too, with the same redaction contract.
  doAssert webhook.url.isSome
  doAssert webhook.url.get.reveal == webhookUrl
  doAssert $webhook.url.get == "[REDACTED]"

block rawJsonRedactsBothCredentials:
  let webhook = decodeWebhook(completeWebhook())
  let raw = webhook.rawJson
  # Neither credential may leak through the only public snapshot accessor.
  doAssert raw["token"].getStr == "[REDACTED]"
  doAssert raw["url"].getStr == "[REDACTED]"
  doAssert "supersecrettoken" notin ($raw)
  doAssert webhookUrl notin ($raw)
  # Non-credential fields still round-trip faithfully.
  doAssert raw["name"].getStr == "test webhook"

block genericRepresentationsNeverLeakCredentials:
  let webhook = decodeWebhook(completeWebhook())
  # `repr` walks private fields, so a snapshot holding the plaintext would leak
  # here; the scrubbed snapshot must not.
  let rendered = repr(webhook)
  doAssert "supersecrettoken" notin rendered
  doAssert webhookUrl notin rendered
  # A plain value copy carries the same scrubbed snapshot, not the plaintext.
  let copied = webhook
  doAssert "supersecrettoken" notin repr(copied)
  doAssert webhookUrl notin repr(copied)
  # The Secret fields redact under `$`, `repr`, and `%`, yet reveal on demand.
  doAssert $webhook.token.get == "[REDACTED]"
  doAssert repr(webhook.token.get) == "[REDACTED]"
  doAssert %webhook.token.get == newJString("[REDACTED]")
  doAssert toJsonHook(webhook.token.get) == newJString("[REDACTED]")
  doAssert webhook.token.get.reveal == "supersecrettoken"
  doAssert webhook.url.get.reveal == webhookUrl

block malformedCredentialTypesRaise:
  # A non-string token or url is a decode error, not a silent drop.
  var badToken = completeWebhook(); badToken["token"] = %123
  doAssertRaises DecodeError:
    discard decodeWebhook(badToken)
  var badUrl = completeWebhook(); badUrl["url"] = %*[1, 2]
  doAssertRaises DecodeError:
    discard decodeWebhook(badUrl)

block unknownWebhookTypePreserved:
  # An unknown type only guarantees id and type, so nothing more is enforced.
  let webhook = decodeWebhook(%*{"id": "1", "type": 99})
  doAssert webhook.kind.knownValue.isNone
  doAssert webhook.kind.toRaw == 99

block missingRequiredFieldsRaise:
  doAssertRaises DecodeError:
    discard decodeWebhook(%*{"type": 1}) # no id
  doAssertRaises DecodeError:
    discard decodeWebhook(%*{"id": "1"}) # no type
  # A known type must carry its required keys.
  for missing in ["name", "avatar", "channel_id", "application_id"]:
    var partial = completeWebhook()
    partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeWebhook(partial)
  # name is required and non-null.
  var nullName = completeWebhook(); nullName["name"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeWebhook(nullName)

block rawSnapshotDeepCopyIsIndependent:
  var payload = completeWebhook()
  payload["surprise"] = %*[1, 2]
  let webhook = decodeWebhook(payload)
  var raw = webhook.rawJson
  raw["surprise"].add(%3)
  doAssert webhook.rawJson["surprise"].len == 2
  doAssert webhook.unknownFields.len == 1
  doAssert webhook.unknownFields[0].name == "surprise"
