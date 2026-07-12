## Focused tests for the semantic channel model.

import std/[json, options]

import cordnim/models/channel

# A complete GuildChannelResponse: id, type, flags, guild_id, name, position.
proc completeGuildChannel(): JsonNode =
  %*{
    "id": "41771983423143937",
    "type": 0,
    "flags": 0,
    "guild_id": "41771983423143937",
    "name": "general",
    "position": 6,
    "nsfw": false,
    "permission_overwrites": [
      {"id": "155117677105512449", "type": 0, "allow": "2048", "deny": "0"}]}

# A complete ThreadResponse.
proc completeThread(): JsonNode =
  %*{
    "id": "12",
    "type": 11,
    "flags": 0,
    "guild_id": "34",
    "parent_id": "34",
    "name": "help-thread",
    "owner_id": "56",
    "message_count": 5,
    "member_count": 3,
    "total_message_sent": 5,
    "thread_metadata": {
      "archived": false,
      "auto_archive_duration": 1440,
      "archive_timestamp": "2026-07-12T09:30:00+00:00",
      "locked": false,
      "create_timestamp": "2026-07-11T09:30:00+00:00"}}

# A guild member object suitable for embedding in a thread member.
proc completeMemberForThread(): JsonNode =
  %*{
    "user": {"id": "80351110224678912", "username": "Nelly",
      "discriminator": "0", "global_name": newJNull(), "avatar": newJNull()},
    "roles": [], "joined_at": "2026-07-01T00:00:00+00:00",
    "deaf": false, "mute": false, "flags": 0}

block decodesGuildTextChannelWithOverwrites:
  let channel = decodeChannel(completeGuildChannel())
  doAssert channel.id.toUint64 == 41771983423143937'u64
  doAssert channel.kind.knownValue == some(ctGuildText)
  doAssert channel.name == some("general")
  doAssert channel.guildId.isSome
  doAssert channel.permissionOverwrites.len == 1
  doAssert channel.permissionOverwrites[0].kind.knownValue == some(owtRole)
  doAssert channel.permissionOverwrites[0].allow.contains(
    Permission.sendMessages)

block decodesThreadWithMetadata:
  let channel = decodeChannel(completeThread())
  doAssert channel.kind.knownValue == some(ctPublicThread)
  doAssert channel.parentId.isSome
  doAssert channel.threadMetadata.isSome
  let meta = channel.threadMetadata.get
  doAssert not meta.archived
  doAssert meta.autoArchiveDuration == 1440
  doAssert meta.archiveTimestamp.iso8601 == "2026-07-12T09:30:00+00:00"
  doAssert meta.createTimestamp.isSome

block threadArchiveTimestampIsRequiredNonNull:
  # The current official object requires a non-null timestamp.
  var nulled = completeThread()
  nulled["thread_metadata"]["archive_timestamp"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeChannel(nulled)
  var missing = completeThread()
  missing["thread_metadata"].delete("archive_timestamp")
  doAssertRaises DecodeError:
    discard decodeChannel(missing)

block decodesForumTagsAndDefaultReaction:
  let channel = decodeChannel(%*{
    "id": "99",
    "type": 15,
    "flags": 0,
    "guild_id": "34",
    "name": "questions",
    "position": 2,
    "available_tags": [
      {"id": "500", "name": "Bug", "moderated": true,
       "emoji_name": "🐛"}],
    "applied_tags": ["500"],
    "default_reaction_emoji": {"emoji_name": "👍"}})
  doAssert channel.kind.knownValue == some(ctGuildForum)
  doAssert channel.availableTags.len == 1
  doAssert channel.availableTags[0].name == "Bug"
  doAssert channel.availableTags[0].moderated
  doAssert channel.availableTags[0].emojiName == some("🐛")
  doAssert channel.appliedTags.len == 1
  doAssert channel.appliedTags[0].toUint64 == 500'u64
  doAssert channel.defaultReactionEmoji.isSome
  doAssert channel.defaultReactionEmoji.get.emojiName == some("👍")

block forumTagEmojiOmittedFieldsAreAccepted:
  # emoji_id and emoji_name are optional and non-null: a forum tag that omits
  # emoji_id but carries emoji_name decodes to a unicode-only tag.
  let unicodeTag = decodeChannel(%*{
    "id": "99", "type": 15, "flags": 0, "guild_id": "34", "name": "q",
    "position": 2,
    "available_tags": [{"id": "500", "name": "Bug", "moderated": true,
      "emoji_name": "🐛"}]})
  doAssert unicodeTag.availableTags[0].emojiId.isNone
  doAssert unicodeTag.availableTags[0].emojiName == some("🐛")
  # A forum tag may also carry a custom emoji_id alone.
  let customTag = decodeChannel(%*{
    "id": "99", "type": 15, "flags": 0, "guild_id": "34", "name": "q",
    "position": 2,
    "available_tags": [{"id": "500", "name": "Bug", "moderated": true,
      "emoji_id": "77"}]})
  doAssert customTag.availableTags[0].emojiId.get.toUint64 == 77'u64
  doAssert customTag.availableTags[0].emojiName.isNone
  # A default reaction with only emoji_id decodes to a custom reaction.
  let customReaction = decodeChannel(%*{
    "id": "99", "type": 15, "flags": 0, "guild_id": "34", "name": "q",
    "position": 2,
    "default_reaction_emoji": {"emoji_id": "88"}})
  doAssert customReaction.defaultReactionEmoji.get.emojiId.get.toUint64 == 88'u64

block decodesGroupDmWithRecipients:
  let channel = decodeChannel(%*{
    "id": "7",
    "type": 3,
    "flags": 0,
    "name": newJNull(),
    "icon": newJNull(),
    "owner_id": "56",
    "recipients": [
      {"id": "1", "username": "a", "discriminator": "0",
       "global_name": newJNull(), "avatar": newJNull(),
       "public_flags": 0, "flags": 0, "primary_guild": newJNull()}]})
  doAssert channel.kind.knownValue == some(ctGroupDm)
  doAssert channel.recipients.len == 1
  doAssert channel.recipients[0].username == "a"

block unknownChannelTypeIsPreserved:
  # An unknown type only guarantees id and type; nothing more is enforced.
  let channel = decodeChannel(%*{"id": "1", "type": 999})
  doAssert channel.kind.knownValue.isNone
  doAssert channel.kind.toRaw == 999
  # The strict response decoder also leaves unknown types at id/type only.
  doAssert decodeChannelResponse(%*{"id": "1", "type": 999}).kind.toRaw == 999

block missingIdOrTypeAlwaysRaise:
  # id and type are required by both the base and response decoders.
  doAssertRaises DecodeError:
    discard decodeChannel(%*{"type": 0}) # no id
  doAssertRaises DecodeError:
    discard decodeChannel(%*{"id": "1"}) # no type

block baseChannelAcceptsGatewayResponseRejects:
  # The base decoder accepts a guild channel missing the REST-required fields
  # (a Gateway CHANNEL_UPDATE need not resend them); the response decoder does
  # not.
  var sparse = completeGuildChannel()
  for k in ["flags", "name", "position"]:
    sparse.delete(k)
  let channel = decodeChannel(sparse)
  doAssert channel.kind.knownValue == some(ctGuildText)
  doAssert channel.name.isNone
  # A guild channel response must carry flags, guild_id, name, and position.
  for missing in ["flags", "guild_id", "name", "position"]:
    var partial = completeGuildChannel(); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeChannelResponse(partial)
  # name is required and non-null for a guild channel: null is rejected too.
  var nullName = completeGuildChannel(); nullName["name"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeChannelResponse(nullName)

block channelResponseVariantRequiredFields:
  # A complete guild channel and thread pass the strict response decoder.
  doAssert decodeChannelResponse(completeGuildChannel()).name == some("general")
  doAssert decodeChannelResponse(completeThread()).threadMetadata.isSome
  # A thread response must additionally carry owner_id, the counts, and metadata.
  for missing in ["owner_id", "total_message_sent", "member_count",
      "thread_metadata"]:
    var partial = completeThread(); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeChannelResponse(partial)
  # A DM channel response must carry recipients.
  doAssertRaises DecodeError:
    discard decodeChannelResponse(%*{"id": "1", "type": 1, "flags": 0})
  # A group DM response requires recipients, owner_id, and present name/icon.
  doAssertRaises DecodeError:
    discard decodeChannelResponse(%*{"id": "7", "type": 3, "flags": 0,
      "recipients": [], "icon": newJNull(), "owner_id": "5"}) # no name key

block decodesNewlyModelledChannelFields:
  # A voice channel carries the previously-unmodelled semantic fields.
  let voice = decodeChannel(%*{
    "id": "10", "type": 2, "flags": 0, "guild_id": "34", "name": "General",
    "position": 1, "bitrate": 64000, "user_limit": 10,
    "video_quality_mode": 2, "rate_limit_per_user": 5,
    "permissions": "2048"})
  doAssert voice.videoQualityMode == some(2'i64)
  doAssert voice.permissions.isSome
  doAssert voice.permissions.get.contains(Permission.sendMessages)
  # A group DM carries application_id and managed.
  let gdm = decodeChannel(%*{
    "id": "7", "type": 3, "flags": 0, "name": newJNull(), "icon": newJNull(),
    "owner_id": "56", "application_id": "999", "managed": true,
    "recipients": []})
  doAssert gdm.applicationId.isSome
  doAssert gdm.applicationId.get.toUint64 == 999'u64
  doAssert gdm.managed == some(true)
  # A forum channel carries total_message_sent and the default thread limit.
  let forum = decodeChannel(%*{
    "id": "99", "type": 15, "flags": 0, "guild_id": "34", "name": "q",
    "position": 2, "total_message_sent": 42,
    "default_thread_rate_limit_per_user": 30})
  doAssert forum.totalMessageSent == some(42'i64)
  doAssert forum.defaultThreadRateLimitPerUser == some(30'i64)

block decodesThreadMember:
  # The thread member object embedded on thread-member endpoints, with a nested
  # guild member returned under with_member.
  let channel = decodeChannel(%*{
    "id": "12", "type": 11, "flags": 0, "guild_id": "34", "name": "t",
    "member": {
      "id": "12", "user_id": "56",
      "join_timestamp": "2026-07-12T09:30:00+00:00", "flags": 1,
      "member": completeMemberForThread()}})
  doAssert channel.member.isSome
  let tm = channel.member.get
  doAssert tm.id.isSome
  doAssert tm.userId.get.toUint64 == 56'u64
  doAssert tm.joinTimestamp.iso8601 == "2026-07-12T09:30:00+00:00"
  doAssert tm.flags == 1
  doAssert tm.member.isSome
  doAssert tm.member.get.user.get.username == "Nelly"
  # id/user_id/member are omitted on a GUILD_CREATE thread member.
  let sparse = decodeChannel(%*{
    "id": "12", "type": 11, "flags": 0, "name": "t",
    "member": {"join_timestamp": "2026-07-12T09:30:00+00:00", "flags": 0}})
  doAssert sparse.member.get.id.isNone
  doAssert sparse.member.get.userId.isNone
  doAssert sparse.member.get.member.isNone
  # join_timestamp and flags are required on a thread member.
  doAssertRaises DecodeError:
    discard decodeChannel(%*{"id": "12", "type": 11, "flags": 0, "name": "t",
      "member": {"flags": 0}})

block channelOptionalNonNullFieldsRejectExplicitNull:
  # The optional non-null fields reject an explicit null instead of collapsing
  # it to absence; the nullable fields still accept null.
  for field in ["guild_id", "position", "permission_overwrites", "nsfw",
      "bitrate", "user_limit", "rate_limit_per_user", "flags",
      "video_quality_mode", "managed", "application_id", "owner_id"]:
    var nulled = completeGuildChannel(); nulled[field] = newJNull()
    doAssertRaises DecodeError:
      discard decodeChannel(nulled)
  # A nullable field such as name or parent_id accepts an explicit null.
  var nullName = completeGuildChannel(); nullName["name"] = newJNull()
  doAssert decodeChannel(nullName).name.isNone
  # total_message_sent and the forum limits reject null too.
  var nullTotal = completeThread(); nullTotal["total_message_sent"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeChannel(nullTotal)

block threadMetadataInvitableIsOptionalNonNull:
  # invitable is optional but non-null: absence is fine, an explicit null is not.
  var withInvitable = completeThread()
  withInvitable["thread_metadata"]["invitable"] = %true
  doAssert decodeChannel(withInvitable).threadMetadata.get.invitable ==
    some(true)
  var nullInvitable = completeThread()
  nullInvitable["thread_metadata"]["invitable"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeChannel(nullInvitable)

proc forumChannel(reaction: JsonNode): JsonNode =
  ## A forum channel wrapping a given default_reaction_emoji object.
  %*{"id": "99", "type": 15, "flags": 0, "guild_id": "34", "name": "q",
    "position": 2, "default_reaction_emoji": reaction}

proc forumChannelTag(tag: JsonNode): JsonNode =
  ## A forum channel wrapping a single available_tags entry.
  %*{"id": "99", "type": 15, "flags": 0, "guild_id": "34", "name": "q",
    "position": 2, "available_tags": [tag]}

block defaultReactionRequiresExactlyOnePresent:
  # Exactly one of emoji_id/emoji_name must be present and non-null.
  # Valid: exactly one present.
  doAssert decodeChannel(forumChannel(%*{"emoji_name": "👍"}))
    .defaultReactionEmoji.get.emojiName == some("👍")
  doAssert decodeChannel(forumChannel(%*{"emoji_id": "88"}))
    .defaultReactionEmoji.get.emojiId.get.toUint64 == 88'u64
  # Both omitted -> zero present -> rejected.
  doAssertRaises DecodeError:
    discard decodeChannel(forumChannel(%*{}))
  # Both present -> rejected.
  doAssertRaises DecodeError:
    discard decodeChannel(forumChannel(%*{"emoji_id": "88", "emoji_name": "👍"}))
  # Explicit null is a malformed payload for either field, not an absent value.
  doAssertRaises DecodeError:
    discard decodeChannel(forumChannel(%*{"emoji_id": newJNull(),
      "emoji_name": "👍"}))
  doAssertRaises DecodeError:
    discard decodeChannel(forumChannel(%*{"emoji_name": newJNull()}))

block forumTagAllowsZeroOrOnePresent:
  # A forum tag permits zero or one present emoji field.
  # Zero present -> a tag with no emoji is valid.
  let noEmoji = decodeChannel(forumChannelTag(
    %*{"id": "500", "name": "Bug", "moderated": false})).availableTags[0]
  doAssert noEmoji.emojiId.isNone
  doAssert noEmoji.emojiName.isNone
  # One present -> valid (covered above); both present -> rejected.
  doAssertRaises DecodeError:
    discard decodeChannel(forumChannelTag(%*{"id": "500", "name": "Bug",
      "moderated": false, "emoji_id": "77", "emoji_name": "🐛"}))
  # Explicit null is rejected for either field.
  doAssertRaises DecodeError:
    discard decodeChannel(forumChannelTag(%*{"id": "500", "name": "Bug",
      "moderated": false, "emoji_id": newJNull()}))
  doAssertRaises DecodeError:
    discard decodeChannel(forumChannelTag(%*{"id": "500", "name": "Bug",
      "moderated": false, "emoji_name": newJNull()}))

block channelSnapshotRetainsNewFieldsAsConsumed:
  # The newly-modelled fields are consumed, not surfaced as unknown.
  let channel = decodeChannel(%*{
    "id": "10", "type": 2, "flags": 0, "guild_id": "34", "name": "v",
    "position": 1, "video_quality_mode": 2, "application_id": "5",
    "managed": false, "total_message_sent": 0,
    "default_thread_rate_limit_per_user": 0, "permissions": "0",
    "surprise_field": 123})
  var names: seq[string]
  for field in channel.unknownFields:
    names.add(field.name)
  doAssert names == @["surprise_field"]
