## Semantic model for Discord channels, threads, and forum metadata.

import std/[json, options]

import ./common
import ./user
import ./member
import ./message

export common
export user
export member
export message

type
  ChannelType* = enum ## Discord channel and thread kinds.
    ctGuildText = 0 ## Text channel within a guild.
    ctDm = 1 ## Direct message between two users.
    ctGuildVoice = 2 ## Voice channel within a guild.
    ctGroupDm = 3 ## Direct message among several users.
    ctGuildCategory = 4 ## Organizational category.
    ctGuildAnnouncement = 5 ## Announcement channel others can follow.
    ctAnnouncementThread = 10 ## Thread under an announcement channel.
    ctPublicThread = 11 ## Public thread under a text or forum channel.
    ctPrivateThread = 12 ## Invite-only thread.
    ctGuildStageVoice = 13 ## Stage channel for hosted audio.
    ctGuildDirectory = 14 ## Hub directory listing.
    ctGuildForum = 15 ## Container of forum threads.
    ctGuildMedia = 16 ## Container of media threads.

  OverwriteType* = enum ## Subject a permission overwrite applies to.
    owtRole = 0 ## Overwrite targets a role.
    owtMember = 1 ## Overwrite targets a single member.

  PermissionOverwrite* = object ## A per-channel permission override.
    id*: uint64 ## Snowflake of the target role or member.
    kind*: OpenEnum[OverwriteType, int] ## Whether the target is role or member.
    allow*: Permissions ## Explicitly granted permission bits.
    deny*: Permissions ## Explicitly denied permission bits.

  ThreadMetadata* = object ## Thread-specific channel settings.
    archived*: bool ## Whether the thread is archived.
    autoArchiveDuration*: int64 ## Minutes of inactivity before auto-archiving.
    archiveTimestamp*: Timestamp ## When the archive state last changed.
    locked*: bool ## Whether only managers may unarchive the thread.
    invitable*: Option[bool] ## Whether non-moderators may add members, for
                             ## private threads.
    createTimestamp*: Option[Timestamp] ## When the thread was created, for
                                        ## threads made after 2022-01-09.

  ForumTag* = object ## A selectable tag available in a forum channel.
    id*: ForumTagId ## Unique snowflake identity of the tag.
    name*: string ## Displayed tag name.
    moderated*: bool ## Whether only moderators may apply the tag.
    emojiId*: Option[EmojiId] ## Custom emoji shown with the tag, when any.
    emojiName*: Option[string] ## Unicode emoji shown with the tag, when any.

  DefaultReaction* = object ## The default forum reaction emoji.
    emojiId*: Option[EmojiId] ## Custom emoji identity, when custom.
    emojiName*: Option[string] ## Unicode emoji, when unicode.

  ThreadMember* = object ## Membership of the current user in a thread.
    ##
    ## `id`, `userId`, and `member` are omitted on the thread members embedded in
    ## a `GUILD_CREATE` event, so they are optional; `member` is additionally
    ## only present when a thread-member endpoint is called with `with_member`.
    id*: Option[ChannelId] ## Thread the membership refers to, when present.
    userId*: Option[UserId] ## User the membership refers to, when present.
    joinTimestamp*: Timestamp ## When the user last joined the thread.
    flags*: int64 ## User-thread notification setting bits.
    member*: Option[GuildMember] ## The user's guild member, when requested.
    snapshot: DiscordSnapshot ## Retained decode evidence for the membership.

  ThreadListing* = object ## A page of active or archived threads.
    threads*: seq[Channel] ## Threads returned by the listing operation.
    members*: seq[ThreadMember] ## Membership records accompanying the threads.
    hasMore*: bool ## Whether another archived-thread page remains.
    firstMessages*: seq[Message] ## Forum starter messages, when included.
    snapshot: DiscordSnapshot ## Retained decode evidence for the listing.

  FollowedChannel* = object ## Result of following an announcement channel.
    channelId*: ChannelId ## Destination channel receiving published messages.
    webhookId*: WebhookId ## Webhook Discord created for the follow.
    snapshot: DiscordSnapshot ## Retained decode evidence for the result.

  Channel* = object ## A decoded Discord channel, thread, or forum.
    id*: ChannelId ## Unique snowflake identity of the channel.
    kind*: OpenEnum[ChannelType, int] ## Channel or thread kind.
    guildId*: Option[GuildId] ## Owning guild, for guild channels.
    position*: Option[int64] ## Sort position among sibling channels.
    permissionOverwrites*: seq[PermissionOverwrite] ## Explicit permission
                                                    ## overrides.
    name*: Option[string] ## Channel name, when it has one.
    topic*: Option[string] ## Channel topic, when set.
    nsfw*: Option[bool] ## Whether the channel is age-restricted.
    lastMessageId*: Option[MessageId] ## Most recent message, when any.
    bitrate*: Option[int64] ## Voice bitrate, for voice channels.
    userLimit*: Option[int64] ## Voice member cap, for voice channels.
    rateLimitPerUser*: Option[int64] ## Slow-mode seconds per user.
    recipients*: seq[User] ## Participants, for DM and group DM channels.
    icon*: Option[string] ## Group DM icon hash, when set.
    ownerId*: Option[UserId] ## Creator, for group DMs and threads.
    applicationId*: Option[ApplicationId] ## Bot that created a group DM, when any.
    managed*: Option[bool] ## Whether an app manages a group DM via `gdm.join`.
    parentId*: Option[ChannelId] ## Parent category, text channel, or forum.
    lastPinTimestamp*: Option[Timestamp] ## When a message was last pinned.
    rtcRegion*: Option[string] ## Voice region override, when pinned.
    videoQualityMode*: Option[int64] ## Voice video quality mode wire value.
    messageCount*: Option[int64] ## Approximate message count, for threads.
    memberCount*: Option[int64] ## Approximate member count, for threads.
    threadMetadata*: Option[ThreadMetadata] ## Thread settings, for threads.
    member*: Option[ThreadMember] ## Current user's thread membership, when
                                  ## returned by a thread-member endpoint.
    defaultAutoArchiveDuration*: Option[int64] ## Default thread archive
                                               ## duration in minutes.
    permissions*: Option[Permissions] ## Computed permissions for the invoking
                                      ## user, in interaction `resolved` data.
    flags*: Option[int64] ## Channel flag bits, when present.
    totalMessageSent*: Option[int64] ## Lifetime message total, for threads.
    availableTags*: seq[ForumTag] ## Tags forum threads may use.
    appliedTags*: seq[ForumTagId] ## Tags applied to a forum thread.
    defaultReactionEmoji*: Option[DefaultReaction] ## Default forum reaction.
    defaultThreadRateLimitPerUser*: Option[int64] ## Slow-mode seconds copied
                                                   ## onto new threads.
    defaultForumLayout*: Option[int64] ## Default forum layout wire value.
    defaultSortOrder*: Option[int64] ## Default forum sort order wire value.
    snapshot: DiscordSnapshot ## Retained decode evidence for the channel.

proc decodeOverwrite(node: JsonNode): PermissionOverwrite =
  let obj = ensureObject(node, "channel.overwrite")
  result.id = decodeId(
    Id[UserKind], requireField(obj, "id", "channel.overwrite"),
    "channel.overwrite.id").toUint64
  result.kind = decodeIntEnum(OverwriteType,
    requireField(obj, "type", "channel.overwrite"), "channel.overwrite.type")
  result.allow = decodePermissions(
    requireField(obj, "allow", "channel.overwrite"), "channel.overwrite.allow")
  result.deny = decodePermissions(
    requireField(obj, "deny", "channel.overwrite"), "channel.overwrite.deny")

proc decodeThreadMetadata(node: JsonNode): ThreadMetadata =
  let obj = ensureObject(node, "channel.thread_metadata")
  result.archived = asBool(
    requireField(obj, "archived", "channel.thread_metadata"),
    "channel.thread_metadata.archived")
  result.autoArchiveDuration = asInt(
    requireField(obj, "auto_archive_duration", "channel.thread_metadata"),
    "channel.thread_metadata.auto_archive_duration")
  result.archiveTimestamp = decodeTimestamp(
    requireField(obj, "archive_timestamp", "channel.thread_metadata"),
    "channel.thread_metadata.archive_timestamp")
  result.locked = asBool(
    requireField(obj, "locked", "channel.thread_metadata"),
    "channel.thread_metadata.locked")
  # `invitable` is optional but non-null: an explicit `null` is rejected.
  result.invitable = optNonNullBool(obj, "invitable", "channel.thread_metadata")
  result.createTimestamp = optTimestamp(
    obj, "create_timestamp", "channel.thread_metadata")

proc decodeThreadMember*(node: JsonNode): ThreadMember =
  ## Decodes the context-neutral thread-member object.
  ##
  ## `id` and `user_id` may be absent on records embedded in `GUILD_CREATE`.
  ## REST endpoints should use `decodeThreadMemberResponse` instead.
  let obj = ensureObject(node, "channel.member")
  # `id`, `user_id`, and `member` are omitted on GUILD_CREATE thread members and
  # are non-null when present; `join_timestamp` and `flags` are always present.
  result.id = optNonNullId(ChannelId, obj, "id", "channel.member")
  result.userId = optNonNullId(UserId, obj, "user_id", "channel.member")
  result.joinTimestamp = decodeTimestamp(
    requireField(obj, "join_timestamp", "channel.member"),
    "channel.member.join_timestamp")
  result.flags = asInt(
    requireField(obj, "flags", "channel.member"), "channel.member.flags")
  let member = optNonNullObject(obj, "member", "channel.member")
  if member.isSome:
    result.member = some(decodeGuildMember(member.get))
  result.snapshot = initSnapshot(obj,
    ["id", "user_id", "join_timestamp", "flags", "member"])

proc decodeThreadMemberResponse*(node: JsonNode): ThreadMember =
  ## Decodes the strict pinned REST thread-member response.
  let obj = ensureObject(node, "thread member")
  requireNonNull(obj, "id", "thread member", {JString})
  requireNonNull(obj, "user_id", "thread member", {JString})
  result = decodeThreadMember(node)

proc decodeForumTag(node: JsonNode): ForumTag =
  let obj = ensureObject(node, "channel.forum_tag")
  result.id = decodeId(ForumTagId,
    requireField(obj, "id", "channel.forum_tag"), "channel.forum_tag.id")
  result.name = asString(
    requireField(obj, "name", "channel.forum_tag"), "channel.forum_tag.name")
  result.moderated = asBool(
    requireField(obj, "moderated", "channel.forum_tag"),
    "channel.forum_tag.moderated")
  # `emoji_id` and `emoji_name` are optional and non-null in the current
  # official object: each is omitted when unset, never sent as `null`, and at
  # most one may be present (a custom id or a unicode name).
  result.emojiId = optNonNullId(EmojiId, obj, "emoji_id", "channel.forum_tag")
  result.emojiName = optNonNullString(obj, "emoji_name", "channel.forum_tag")
  if result.emojiId.isSome and result.emojiName.isSome:
    raiseDecode(
      "channel.forum_tag may set at most one of emoji_id or emoji_name")

proc decodeDefaultReaction(node: JsonNode): DefaultReaction =
  let obj = ensureObject(node, "channel.default_reaction")
  # Both fields are optional and non-null in the current official object: each
  # is omitted when unset, never sent as `null`, and exactly one must be present
  # (a custom id or a unicode name).
  result.emojiId = optNonNullId(
    EmojiId, obj, "emoji_id", "channel.default_reaction")
  result.emojiName = optNonNullString(
    obj, "emoji_name", "channel.default_reaction")
  if result.emojiId.isSome == result.emojiName.isSome:
    raiseDecode(
      "channel.default_reaction must set exactly one of emoji_id or emoji_name")

const
  guildChannelTypes = {0, 2, 4, 5, 13, 14, 15, 16}
    ## Channel `type` values covered by GuildChannelResponse.
  threadChannelTypes = {10, 11, 12}
    ## Channel `type` values covered by ThreadResponse.

proc enforceChannelRequired(obj: JsonNode; kindRaw: int) =
  ## Validates the required fields of the pinned channel-response variant
  ## selected by `kindRaw`, checking presence, nullability, and JSON type.
  ## Unknown channel types only require `id`/`type`, which the caller has
  ## already validated, so no extra fields are enforced; `flags` is required and
  ## non-null in every known variant.
  if kindRaw in guildChannelTypes:
    requireNonNull(obj, "flags", "channel", {JInt})
    requireNonNull(obj, "guild_id", "channel", {JString})
    requireNonNull(obj, "name", "channel", {JString})
    requireNonNull(obj, "position", "channel", {JInt})
  elif kindRaw in threadChannelTypes:
    requireNonNull(obj, "flags", "channel", {JInt})
    requireNonNull(obj, "guild_id", "channel", {JString})
    requireNonNull(obj, "name", "channel", {JString})
    requireNonNull(obj, "owner_id", "channel", {JString})
    requireNonNull(obj, "thread_metadata", "channel", {JObject})
    requireNonNull(obj, "message_count", "channel", {JInt})
    requireNonNull(obj, "member_count", "channel", {JInt})
    requireNonNull(obj, "total_message_sent", "channel", {JInt})
  elif kindRaw == 1: # PrivateChannelResponse (DM)
    requireNonNull(obj, "flags", "channel", {JInt})
    requireNonNull(obj, "recipients", "channel", {JArray})
  elif kindRaw == 3: # PrivateGroupChannelResponse (group DM)
    requireNonNull(obj, "flags", "channel", {JInt})
    requireNonNull(obj, "recipients", "channel", {JArray})
    requireNonNull(obj, "owner_id", "channel", {JString})
    # `name` and `icon` are required for a group DM but nullable.
    requireNullablePresent(obj, "name", "channel", {JString})
    requireNullablePresent(obj, "icon", "channel", {JString})

proc decodeChannel*(node: JsonNode): Channel =
  ## Decodes a channel using the context-neutral official object contract.
  ##
  ## Every field beyond `id` and `type` is optional here, so Gateway payloads
  ## that omit `flags`, `guild_id`, `name`, `position`, or the thread counts
  ## decode without error. Use `decodeChannelResponse` to additionally enforce
  ## the pinned REST required fields for the channel's variant.
  let obj = ensureObject(node, "channel")
  result.id = decodeId(ChannelId,
    requireField(obj, "id", "channel"), "channel.id")
  result.kind = decodeIntEnum(ChannelType,
    requireField(obj, "type", "channel"), "channel.type")
  # Optional non-null fields reject an explicit `null`; only the officially
  # nullable fields (name, topic, icon, parent_id, last_pin_timestamp,
  # rtc_region, default_reaction_emoji, default_sort_order, and the nullable
  # snowflakes) collapse `null` to `none`.
  result.guildId = optNonNullId(GuildId, obj, "guild_id", "channel")
  result.position = optNonNullInt(obj, "position", "channel")
  let overwrites = optNonNullArray(obj, "permission_overwrites", "channel")
  if overwrites.isSome:
    for owNode in overwrites.get:
      result.permissionOverwrites.add(decodeOverwrite(owNode))
  result.name = optString(obj, "name", "channel")
  result.topic = optString(obj, "topic", "channel")
  result.nsfw = optNonNullBool(obj, "nsfw", "channel")
  result.lastMessageId = optId(MessageId, obj, "last_message_id", "channel")
  result.bitrate = optNonNullInt(obj, "bitrate", "channel")
  result.userLimit = optNonNullInt(obj, "user_limit", "channel")
  result.rateLimitPerUser = optNonNullInt(obj, "rate_limit_per_user", "channel")
  let recipients = optNonNullArray(obj, "recipients", "channel")
  if recipients.isSome:
    for userNode in recipients.get:
      result.recipients.add(decodeUser(userNode))
  result.icon = optString(obj, "icon", "channel")
  result.ownerId = optNonNullId(UserId, obj, "owner_id", "channel")
  result.applicationId = optNonNullId(
    ApplicationId, obj, "application_id", "channel")
  result.managed = optNonNullBool(obj, "managed", "channel")
  result.parentId = optId(ChannelId, obj, "parent_id", "channel")
  result.lastPinTimestamp = optTimestamp(obj, "last_pin_timestamp", "channel")
  result.rtcRegion = optString(obj, "rtc_region", "channel")
  result.videoQualityMode = optNonNullInt(
    obj, "video_quality_mode", "channel")
  result.messageCount = optNonNullInt(obj, "message_count", "channel")
  result.memberCount = optNonNullInt(obj, "member_count", "channel")
  let threadMeta = optNonNullObject(obj, "thread_metadata", "channel")
  if threadMeta.isSome:
    result.threadMetadata = some(decodeThreadMetadata(threadMeta.get))
  let threadMember = optNonNullObject(obj, "member", "channel")
  if threadMember.isSome:
    result.member = some(decodeThreadMember(threadMember.get))
  result.defaultAutoArchiveDuration = optNonNullInt(
    obj, "default_auto_archive_duration", "channel")
  let permissions = optionalNonNullField(obj, "permissions", "channel")
  if permissions.isSome:
    result.permissions = some(decodePermissions(
      permissions.get, "channel.permissions"))
  result.flags = optNonNullInt(obj, "flags", "channel")
  result.totalMessageSent = optNonNullInt(obj, "total_message_sent", "channel")
  let tags = optNonNullArray(obj, "available_tags", "channel")
  if tags.isSome:
    for tagNode in tags.get:
      result.availableTags.add(decodeForumTag(tagNode))
  let applied = optNonNullArray(obj, "applied_tags", "channel")
  if applied.isSome:
    for index, tagNode in applied.get:
      result.appliedTags.add(decodeId(ForumTagId, tagNode,
        "channel.applied_tags[" & $index & "]"))
  let defaultReaction = optionalField(obj, "default_reaction_emoji")
  if defaultReaction.isSome:
    result.defaultReactionEmoji = some(
      decodeDefaultReaction(defaultReaction.get))
  result.defaultThreadRateLimitPerUser = optNonNullInt(
    obj, "default_thread_rate_limit_per_user", "channel")
  result.defaultForumLayout = optNonNullInt(
    obj, "default_forum_layout", "channel")
  result.defaultSortOrder = optInt(obj, "default_sort_order", "channel")
  result.snapshot = initSnapshot(obj, [
    "id", "type", "guild_id", "position", "permission_overwrites", "name",
    "topic", "nsfw", "last_message_id", "bitrate", "user_limit",
    "rate_limit_per_user", "recipients", "icon", "owner_id", "application_id",
    "managed", "parent_id", "last_pin_timestamp", "rtc_region",
    "video_quality_mode", "message_count", "member_count", "thread_metadata",
    "member", "total_message_sent", "default_auto_archive_duration",
    "permissions", "flags", "available_tags", "applied_tags",
    "default_reaction_emoji", "default_thread_rate_limit_per_user",
    "default_forum_layout", "default_sort_order"])

proc decodeChannelResponse*(node: JsonNode): Channel =
  ## Decodes a channel under the strict pinned REST contract for its variant.
  ##
  ## Selects the response schema from the channel `type` and enforces that
  ## variant's required fields (for a guild channel: `flags`, `guild_id`,
  ## `name`, `position`; for a thread additionally `owner_id`,
  ## `thread_metadata`, and the message/member counts; for DMs `recipients`).
  ## Unknown channel types only require `id`/`type`, exactly as the base decoder.
  result = decodeChannel(node)
  enforceChannelRequired(ensureObject(node, "channel"), result.kind.toRaw)

proc decodeThreadListing*(node: JsonNode): ThreadListing =
  ## Decodes the strict thread-listing response used by active and archived
  ## thread endpoints.
  let obj = ensureObject(node, "thread listing")
  for item in asArray(requireField(obj, "threads", "thread listing"),
      "thread listing.threads"):
    result.threads.add(decodeChannelResponse(item))
  for item in asArray(requireField(obj, "members", "thread listing"),
      "thread listing.members"):
    result.members.add(decodeThreadMemberResponse(item))
  result.hasMore = asBool(requireField(obj, "has_more", "thread listing"),
    "thread listing.has_more")
  let firstMessages = optNonNullArray(
    obj, "first_messages", "thread listing")
  if firstMessages.isSome:
    for item in firstMessages.get:
      result.firstMessages.add(decodeMessage(item))
  result.snapshot = initSnapshot(obj,
    ["threads", "members", "has_more", "first_messages"])

proc decodeFollowedChannel*(node: JsonNode): FollowedChannel =
  ## Decodes the result of following an announcement channel.
  let obj = ensureObject(node, "followed channel")
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "followed channel"),
    "followed channel.channel_id")
  result.webhookId = decodeId(WebhookId,
    requireField(obj, "webhook_id", "followed channel"),
    "followed channel.webhook_id")
  result.snapshot = initSnapshot(obj, ["channel_id", "webhook_id"])

proc parseChannel*(text: string): Channel =
  ## Decodes a Discord channel (base contract) from a JSON document string.
  decodeChannel(parseJsonObject(text, "channel"))

proc parseChannelResponse*(text: string): Channel =
  ## Decodes a channel under the strict REST contract from a JSON document.
  decodeChannelResponse(parseJsonObject(text, "channel"))

proc parseThreadMemberResponse*(text: string): ThreadMember =
  ## Decodes a strict REST thread-member response from a JSON document.
  decodeThreadMemberResponse(parseJsonObject(text, "thread member"))

proc parseThreadListing*(text: string): ThreadListing =
  ## Decodes a thread listing from a JSON document.
  decodeThreadListing(parseJsonObject(text, "thread listing"))

proc parseFollowedChannel*(text: string): FollowedChannel =
  ## Decodes an announcement-follow result from a JSON document.
  decodeFollowedChannel(parseJsonObject(text, "followed channel"))

proc rawJson*(channel: Channel): JsonNode =
  ## Returns an independent deep copy of the channel's original JSON.
  rawJson(channel.snapshot)

proc unknownFields*(channel: Channel): seq[UnknownField] =
  ## Returns deep copies of channel fields not consumed by the decoder.
  unknownFields(channel.snapshot)

proc rawJson*(member: ThreadMember): JsonNode =
  ## Returns an independent deep copy of the membership's original JSON.
  rawJson(member.snapshot)

proc unknownFields*(member: ThreadMember): seq[UnknownField] =
  ## Returns unconsumed membership fields.
  unknownFields(member.snapshot)

proc rawJson*(listing: ThreadListing): JsonNode =
  ## Returns an independent deep copy of the listing's original JSON.
  rawJson(listing.snapshot)

proc unknownFields*(listing: ThreadListing): seq[UnknownField] =
  ## Returns unconsumed top-level listing fields.
  unknownFields(listing.snapshot)

proc rawJson*(followed: FollowedChannel): JsonNode =
  ## Returns an independent deep copy of the follow result's original JSON.
  rawJson(followed.snapshot)

proc unknownFields*(followed: FollowedChannel): seq[UnknownField] =
  ## Returns unconsumed top-level follow-result fields.
  unknownFields(followed.snapshot)
