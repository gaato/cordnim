## Focused tests for the semantic message model.

import std/[json, options]

import cordnim/models/message

# A complete UserResponse for embedding.
proc completeUser(id, username: string): JsonNode =
  %*{"id": id, "username": username, "discriminator": "0",
     "global_name": newJNull(), "avatar": newJNull(),
     "public_flags": 0, "flags": 0, "primary_guild": newJNull()}

# A complete MessageResponse, including a fully-formed reaction tally and the
# required `edited_timestamp`, `flags`, and `components` keys.
proc completeMessage(): JsonNode =
  %*{
    "id": "334385199974967042",
    "channel_id": "290926798999357250",
    "author": completeUser("80351110224678912", "Nelly"),
    "content": "Hey there",
    "timestamp": "2026-07-12T09:30:00+00:00",
    "edited_timestamp": newJNull(),
    "tts": false,
    "mention_everyone": false,
    "mentions": [completeUser("1", "a")],
    "mention_roles": ["11", "22"],
    "attachments": [{"id": "700", "filename": "note.txt", "size": 12,
                     "url": "https://cdn/x", "proxy_url": "https://proxy/x"}],
    "embeds": [{"type": "rich", "title": "Title"}],
    "reactions": [{"count": 3, "me": true,
                   "count_details": {"burst": 0, "normal": 3},
                   "burst_colors": [], "me_burst": false,
                   "emoji": {"id": newJNull(), "name": "🔥"}}],
    "pinned": false,
    "type": 0,
    "flags": 0,
    "components": [],
    "future_field": 123}

block decodesRepresentativeMessage:
  let message = decodeMessage(completeMessage())
  doAssert message.id.toUint64 == 334385199974967042'u64
  doAssert message.channelId.toUint64 == 290926798999357250'u64
  # A user-authored message takes the user branch and decodes a full User.
  doAssert message.author.kind == makUser
  doAssert message.author.user.username == "Nelly"
  doAssert message.content == "Hey there"
  doAssert message.timestamp.iso8601 == "2026-07-12T09:30:00+00:00"
  doAssert not message.tts
  doAssert message.mentions.len == 1
  doAssert message.mentionRoles.len == 2
  doAssert message.mentionRoles[0].toUint64 == 11'u64
  doAssert message.attachments.len == 1
  doAssert message.attachments[0].filename == "note.txt"
  doAssert message.attachments[0].size == 12
  doAssert message.embeds.len == 1
  doAssert message.embeds[0].kind == "rich"
  doAssert message.embeds[0].title == some("Title")
  doAssert message.reactions.len == 1
  doAssert message.reactions[0].count == 3
  doAssert message.reactions[0].emoji.name == some("🔥")
  doAssert message.flags == 0'i64
  doAssert message.kind.knownValue == some(mtDefault)

block editedTimestampRequiredButNullable:
  let message = decodeMessage(completeMessage())
  doAssert message.editedTimestamp.isNone
  # A present, non-null edited_timestamp decodes.
  var edited = completeMessage()
  edited["edited_timestamp"] = %"2026-07-12T10:00:00+00:00"
  doAssert decodeMessage(edited).editedTimestamp.isSome
  # Omitting the required key is rejected, unlike a plain optional field.
  var noEdit = completeMessage(); noEdit.delete("edited_timestamp")
  doAssertRaises DecodeError:
    discard decodeMessage(noEdit)

block unknownMessageTypeIsPreserved:
  var payload = completeMessage()
  payload["type"] = %255
  let message = decodeMessage(payload)
  doAssert message.kind.knownValue.isNone
  doAssert message.kind.toRaw == 255

block referencedMessageIsNonrecursiveBasicMessage:
  var payload = completeMessage()
  payload["type"] = %19
  payload["referenced_message"] = completeMessage()
  let message = decodeMessage(payload)
  doAssert message.referencedMessage.isSome
  # referencedMessage is a BasicMessage value, not a recursive ref.
  let basic: BasicMessage = message.referencedMessage.get
  doAssert basic.content == "Hey there"
  doAssert basic.author.kind == makUser
  doAssert basic.author.user.username == "Nelly"
  # An explicit null referenced_message decodes to none.
  var nulled = completeMessage()
  nulled["referenced_message"] = newJNull()
  doAssert decodeMessage(nulled).referencedMessage.isNone

block pollAttachmentDecodes:
  var payload = completeMessage()
  payload["poll"] = %*{
    "question": {"text": "Best color?"},
    "answers": [
      {"answer_id": 1, "poll_media": {"text": "Red"}},
      {"answer_id": 2, "poll_media": {"text": "Blue"}}],
    "expiry": newJNull(),
    "allow_multiselect": false,
    "layout_type": 1}
  let message = decodeMessage(payload)
  doAssert message.poll.isSome
  doAssert message.poll.get.answers.len == 2
  doAssert message.poll.get.question.text == some("Best color?")

block missingRequiredFieldsRaise:
  doAssertRaises DecodeError:
    discard decodeMessage(%*{"id": "1"}) # almost everything missing
  # A malformed required snowflake is rejected.
  var badId = completeMessage(); badId["channel_id"] = %"not-a-number"
  doAssertRaises DecodeError:
    discard decodeMessage(badId)
  # flags and the unmodelled components key are both required.
  for missing in ["flags", "components", "pinned", "author"]:
    var partial = completeMessage(); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeMessage(partial)

block reactionRequiresFullTally:
  # MessageReactionResponse requires count_details, burst_colors, and me_burst.
  for missing in ["count_details", "burst_colors", "me_burst"]:
    var payload = completeMessage()
    payload["reactions"][0].delete(missing)
    doAssertRaises DecodeError:
      discard decodeMessage(payload)

block unknownFieldsCapturedAndDeepCopied:
  let message = decodeMessage(completeMessage())
  var unknown = message.unknownFields
  doAssert unknown.len == 1
  doAssert unknown[0].name == "future_field"
  # Snapshot retains the full original including consumed fields.
  doAssert message.rawJson["content"].getStr == "Hey there"

block webhookAuthoredMessageDecodes:
  # A real webhook-authored message: `webhook_id` is set and the author carries
  # only id, username, and avatar — not a valid full User. The strict user
  # decoder would reject it; the author overlay must not.
  var payload = completeMessage()
  payload["webhook_id"] = %"223704706495545344"
  payload["author"] = %*{
    "id": "223704706495545344",
    "username": "Captain Hook",
    "avatar": "a1b2c3"}
  let message = decodeMessage(payload)
  doAssert message.webhookId.isSome
  # The author takes the webhook branch, keyed by WebhookId, not UserId.
  doAssert message.author.kind == makWebhook
  doAssert message.author.webhookId.toUint64 == 223704706495545344'u64
  doAssert message.author.username == "Captain Hook"
  doAssert message.author.avatar == some("a1b2c3")
  # Mentions stay strict full users even on a webhook message.
  doAssert message.mentions.len == 1
  doAssert message.mentions[0].username == "a"
  # The raw snapshot round-trips and is owned by the message.
  doAssert message.rawJson["author"]["username"].getStr == "Captain Hook"
  var raw = message.rawJson
  raw["author"]["username"] = %"tampered"
  doAssert message.rawJson["author"]["username"].getStr == "Captain Hook"

  var mismatched = payload.copy()
  mismatched["author"]["id"] = %"223704706495545345"
  doAssertRaises DecodeError:
    discard decodeMessage(mismatched)

block embedTypeIsRequired:
  # MessageEmbedResponse marks `type` required and non-null on a received embed.
  var noType = completeMessage()
  noType["embeds"][0].delete("type")
  doAssertRaises DecodeError:
    discard decodeMessage(noType)
  var nullType = completeMessage()
  nullType["embeds"][0]["type"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeMessage(nullType)

block messageReferenceRequiresTypeAndChannel:
  # A received MessageReference requires a non-null type and channel_id.
  var withRef = completeMessage()
  withRef["message_reference"] = %*{
    "type": 0, "channel_id": "290926798999357250", "message_id": "1"}
  let message = decodeMessage(withRef)
  doAssert message.messageReference.isSome
  doAssert message.messageReference.get.kind.knownValue == some(mrtDefault)
  doAssert message.messageReference.get.channelId.toUint64 ==
    290926798999357250'u64
  doAssert message.messageReference.get.messageId.isSome
  for missing in ["type", "channel_id"]:
    var bad = completeMessage()
    bad["message_reference"] = %*{
      "type": 0, "channel_id": "290926798999357250"}
    bad["message_reference"].delete(missing)
    doAssertRaises DecodeError:
      discard decodeMessage(bad)

block reactionEmojiRequiresPresentNullableIdAndName:
  # MessageReactionEmojiResponse requires id and name to be present (nullable).
  for missing in ["id", "name"]:
    var payload = completeMessage()
    payload["reactions"][0]["emoji"].delete(missing)
    doAssertRaises DecodeError:
      discard decodeMessage(payload)
  # A present null id is fine (unicode emoji), and null name is accepted too.
  var unicode = completeMessage()
  unicode["reactions"][0]["emoji"] = %*{"id": newJNull(), "name": "🔥"}
  doAssert decodeMessage(unicode).reactions[0].emoji.id.isNone

block basicMessageDecodesIndependently:
  # decodeBasicMessage enforces the same required list but ignores reactions.
  let basic = decodeBasicMessage(completeMessage())
  doAssert basic.content == "Hey there"
  doAssert basic.flags == 0'i64
  # reactions is not modelled on BasicMessage, so it surfaces as unknown.
  var names: seq[string]
  for field in basic.unknownFields:
    names.add(field.name)
  doAssert "reactions" in names
  doAssert "future_field" in names
