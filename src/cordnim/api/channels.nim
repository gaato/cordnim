## Semantic guild-channel REST operations.
##
## Request objects validate Discord's current bounds before any network I/O.
## Permission bitsets are always written as decimal strings, preserving values
## wider than 64 bits even where the pinned OpenAPI document says `integer`.

import std/[json, options, sets, unicode]

import chronos

import cordnim/api/fields
import cordnim/api/internal/execute
import cordnim/api/options
import cordnim/models/channel
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/channels as channel_routes
import cordnim/raw/routes/guilds as guild_routes
import cordnim/rest/chronos_driver
import cordnim/rest/request

export channel
export fields
export options

const
  MaxChannelNameLength* = 100
  MaxChannelTopicLength* = 4_096
  MaxChannelPermissionOverwrites* = 100
  MaxForumTags* = 20
  MaxAppliedForumTags* = 5
  MaxChannelSlowmodeSeconds* = 21_600

type
  VideoQualityMode* = enum ## Voice-channel video quality policy.
    vqmAuto = 1
    vqmFull = 2

  ThreadAutoArchiveDuration* = enum ## Supported inactivity windows in minutes.
    taadOneHour = 60
    taadOneDay = 1_440
    taadThreeDays = 4_320
    taadOneWeek = 10_080

  ForumSortOrder* = enum ## Default forum-thread ordering.
    fsoLatestActivity = 0
    fsoCreationDate = 1

  ForumLayout* = enum ## Default forum presentation.
    flNotSet = 0
    flListView = 1
    flGalleryView = 2

  ForumEmoji* = object ## Optional custom or Unicode emoji selection.
    emojiIdValue: Option[EmojiId]
    emojiNameValue: Option[string]

  ForumTagCreate* = object ## A tag accepted by guild forum/media channels.
    nameValue: string
    emojiValue: Option[ForumEmoji]
    moderatedValue: Option[bool]

  PermissionOverwriteEdit* = object ## One role/member channel overwrite.
    targetIdValue: uint64
    kindValue: OverwriteType
    allowValue: Permissions
    denyValue: Permissions

  GuildChannelCreate* = object ## Validated guild-channel creation body.
    nameValue: string
    kindValue: ChannelType
    positionValue: Option[int]
    topicValue: Option[string]
    bitrateValue: Option[int]
    userLimitValue: Option[int]
    nsfwValue: Option[bool]
    slowmodeValue: Option[int]
    parentIdValue: Option[ChannelId]
    overwritesValue: seq[PermissionOverwriteEdit]
    rtcRegionValue: Option[string]
    videoQualityValue: Option[VideoQualityMode]
    autoArchiveValue: Option[ThreadAutoArchiveDuration]
    defaultReactionValue: Option[ForumEmoji]
    defaultThreadSlowmodeValue: Option[int]
    sortOrderValue: Option[ForumSortOrder]
    forumLayoutValue: Option[ForumLayout]
    tagsValue: seq[ForumTagCreate]

  ChannelEdit* = object ## Validated channel/thread PATCH body.
    kindValue: FieldEdit[ChannelType]
    nameValue: FieldEdit[string]
    positionValue: FieldEdit[int]
    topicValue: FieldEdit[string]
    bitrateValue: FieldEdit[int]
    userLimitValue: FieldEdit[int]
    nsfwValue: FieldEdit[bool]
    slowmodeValue: FieldEdit[int]
    parentIdValue: FieldEdit[ChannelId]
    overwritesValue: FieldEdit[seq[PermissionOverwriteEdit]]
    rtcRegionValue: FieldEdit[string]
    videoQualityValue: FieldEdit[VideoQualityMode]
    autoArchiveValue: FieldEdit[ThreadAutoArchiveDuration]
    defaultReactionValue: FieldEdit[ForumEmoji]
    defaultThreadSlowmodeValue: FieldEdit[int]
    sortOrderValue: FieldEdit[ForumSortOrder]
    forumLayoutValue: FieldEdit[ForumLayout]
    flagsValue: FieldEdit[int64]
    tagsValue: FieldEdit[seq[ForumTagCreate]]
    archivedValue: FieldEdit[bool]
    lockedValue: FieldEdit[bool]
    invitableValue: FieldEdit[bool]
    appliedTagsValue: FieldEdit[seq[ForumTagId]]

  ChannelPosition* = object ## One channel move in a guild reorder request.
    channelIdValue: ChannelId
    positionValue: Option[int]
    parentIdValue: FieldEdit[ChannelId]
    lockPermissionsValue: Option[bool]

proc validateText(value, label: string; minRunes, maxRunes: int) =
  if value.validateUtf8 != -1:
    raise newException(ValueError, label & " must be valid UTF-8")
  let length = value.runeLen
  if length < minRunes or length > maxRunes:
    raise newException(ValueError, label & " must contain between " &
      $minRunes & " and " & $maxRunes & " characters")

proc requireNonzero[Kind](id: Id[Kind]; label: string) =
  if id.toUint64 == 0:
    raise newException(ValueError, label & " must be greater than zero")

proc validateChannelKind(kind: ChannelType) =
  if ord(kind) notin [0, 2, 4, 5, 13, 14, 15]:
    raise newException(ValueError,
      "guild channel type must be a guild channel, not a DM or thread")

proc validateSlowmode(value: int; label: string) =
  if value < 0 or value > MaxChannelSlowmodeSeconds:
    raise newException(ValueError, label & " must be between 0 and " &
      $MaxChannelSlowmodeSeconds & " seconds")

proc validateVoice(bitrate, userLimit: Option[int]) =
  if bitrate.isSome and bitrate.get < 8_000:
    raise newException(ValueError, "channel bitrate must be at least 8000")
  if userLimit.isSome and userLimit.get < 0:
    raise newException(ValueError, "channel user limit must not be negative")

proc validateEmoji(value: ForumEmoji) =
  if value.emojiIdValue.isSome == value.emojiNameValue.isSome:
    raise newException(ValueError,
      "forum emoji must set exactly one of emojiId or emojiName")
  if value.emojiIdValue.isSome:
    value.emojiIdValue.get.requireNonzero("forum emoji ID")
  if value.emojiNameValue.isSome:
    value.emojiNameValue.get.validateText("forum emoji name", 1, 100)

func customForumEmoji*(emojiId: EmojiId): ForumEmoji =
  ## Selects one custom emoji.
  emojiId.requireNonzero("forum emoji ID")
  ForumEmoji(emojiIdValue: some(emojiId))

func unicodeForumEmoji*(name: string): ForumEmoji =
  ## Selects one Unicode emoji string.
  name.validateText("forum emoji name", 1, 100)
  ForumEmoji(emojiNameValue: some(name))

proc forumTag*(name: string; emoji = none(ForumEmoji);
               moderated = none(bool)): ForumTagCreate =
  ## Builds one forum tag. Emoji choice is structurally exclusive.
  name.validateText("forum tag name", 1, 50)
  if emoji.isSome:
    emoji.get.validateEmoji()
  ForumTagCreate(nameValue: name, emojiValue: emoji,
    moderatedValue: moderated)

func roleOverwrite*(roleId: RoleId;
                    allow = initDiscordBits[Permission]();
                    deny = initDiscordBits[Permission]()):
                    PermissionOverwriteEdit =
  ## Builds a role-targeted permission overwrite.
  roleId.requireNonzero("permission overwrite role ID")
  PermissionOverwriteEdit(targetIdValue: roleId.toUint64,
    kindValue: owtRole, allowValue: allow, denyValue: deny)

func memberOverwrite*(userId: UserId;
                      allow = initDiscordBits[Permission]();
                      deny = initDiscordBits[Permission]()):
                      PermissionOverwriteEdit =
  ## Builds a member-targeted permission overwrite.
  userId.requireNonzero("permission overwrite user ID")
  PermissionOverwriteEdit(targetIdValue: userId.toUint64,
    kindValue: owtMember, allowValue: allow, denyValue: deny)

proc validateOverwrite(value: PermissionOverwriteEdit) =
  if value.targetIdValue == 0:
    raise newException(ValueError,
      "permission overwrite target ID must be greater than zero")

proc validateOverwrites(values: openArray[PermissionOverwriteEdit]) =
  if values.len > MaxChannelPermissionOverwrites:
    raise newException(ValueError, "a channel cannot contain more than " &
      $MaxChannelPermissionOverwrites & " permission overwrites")
  var seen = initHashSet[(uint64, OverwriteType)]()
  for value in values:
    value.validateOverwrite()
    let key = (value.targetIdValue, value.kindValue)
    if key in seen:
      raise newException(ValueError,
        "permission overwrite targets must be unique")
    seen.incl(key)

proc validateTags(values: openArray[ForumTagCreate]) =
  if values.len > MaxForumTags:
    raise newException(ValueError,
      "a forum channel cannot contain more than " & $MaxForumTags & " tags")
  var names = initHashSet[string]()
  for value in values:
    value.nameValue.validateText("forum tag name", 1, 50)
    if value.nameValue in names:
      raise newException(ValueError, "forum tag names must be unique")
    names.incl(value.nameValue)
    if value.emojiValue.isSome:
      value.emojiValue.get.validateEmoji()

proc guildChannelCreate*(name: string;
                         kind = ctGuildText;
                         position = none(int);
                         topic = none(string);
                         bitrate = none(int);
                         userLimit = none(int);
                         nsfw = none(bool);
                         rateLimitPerUser = none(int);
                         parentId = none(ChannelId);
                         permissionOverwrites: seq[PermissionOverwriteEdit] = @[];
                         rtcRegion = none(string);
                         videoQualityMode = none(VideoQualityMode);
                         defaultAutoArchiveDuration =
                           none(ThreadAutoArchiveDuration);
                         defaultReactionEmoji = none(ForumEmoji);
                         defaultThreadRateLimitPerUser = none(int);
                         defaultSortOrder = none(ForumSortOrder);
                         defaultForumLayout = none(ForumLayout);
                         availableTags: seq[ForumTagCreate] = @[]):
                         GuildChannelCreate =
  ## Builds a guild channel, including voice and forum-specific settings.
  name.validateText("channel name", 1, MaxChannelNameLength)
  kind.validateChannelKind()
  if position.isSome and position.get < 0:
    raise newException(ValueError, "channel position must not be negative")
  if topic.isSome:
    topic.get.validateText("channel topic", 0, MaxChannelTopicLength)
  validateVoice(bitrate, userLimit)
  if rateLimitPerUser.isSome:
    rateLimitPerUser.get.validateSlowmode("channel slowmode")
  if parentId.isSome:
    parentId.get.requireNonzero("channel parent ID")
  permissionOverwrites.validateOverwrites()
  if defaultReactionEmoji.isSome:
    defaultReactionEmoji.get.validateEmoji()
  if defaultThreadRateLimitPerUser.isSome:
    defaultThreadRateLimitPerUser.get.validateSlowmode(
      "default thread slowmode")
  availableTags.validateTags()
  GuildChannelCreate(nameValue: name, kindValue: kind,
    positionValue: position, topicValue: topic, bitrateValue: bitrate,
    userLimitValue: userLimit, nsfwValue: nsfw,
    slowmodeValue: rateLimitPerUser, parentIdValue: parentId,
    overwritesValue: permissionOverwrites, rtcRegionValue: rtcRegion,
    videoQualityValue: videoQualityMode, autoArchiveValue:
      defaultAutoArchiveDuration, defaultReactionValue: defaultReactionEmoji,
    defaultThreadSlowmodeValue: defaultThreadRateLimitPerUser,
    sortOrderValue: defaultSortOrder, forumLayoutValue: defaultForumLayout,
    tagsValue: availableTags)

proc channelEdit*(kind = editOmit(ChannelType);
                  name = editOmit(string);
                  position = editOmit(int);
                  topic = editOmit(string);
                  bitrate = editOmit(int);
                  userLimit = editOmit(int);
                  nsfw = editOmit(bool);
                  rateLimitPerUser = editOmit(int);
                  parentId = editOmit(ChannelId);
                  permissionOverwrites =
                    editOmit(seq[PermissionOverwriteEdit]);
                  rtcRegion = editOmit(string);
                  videoQualityMode = editOmit(VideoQualityMode);
                  autoArchiveDuration =
                    editOmit(ThreadAutoArchiveDuration);
                  defaultReactionEmoji = editOmit(ForumEmoji);
                  defaultThreadRateLimitPerUser = editOmit(int);
                  defaultSortOrder = editOmit(ForumSortOrder);
                  defaultForumLayout = editOmit(ForumLayout);
                  flags = editOmit(int64);
                  availableTags = editOmit(seq[ForumTagCreate]);
                  archived = editOmit(bool);
                  locked = editOmit(bool);
                  invitable = editOmit(bool);
                  appliedTags = editOmit(seq[ForumTagId])): ChannelEdit =
  ## Builds a channel or thread edit with explicit omit/null/set semantics.
  ChannelEdit(kindValue: kind, nameValue: name, positionValue: position,
    topicValue: topic, bitrateValue: bitrate, userLimitValue: userLimit,
    nsfwValue: nsfw, slowmodeValue: rateLimitPerUser,
    parentIdValue: parentId, overwritesValue: permissionOverwrites,
    rtcRegionValue: rtcRegion, videoQualityValue: videoQualityMode,
    autoArchiveValue: autoArchiveDuration,
    defaultReactionValue: defaultReactionEmoji,
    defaultThreadSlowmodeValue: defaultThreadRateLimitPerUser,
    sortOrderValue: defaultSortOrder, forumLayoutValue: defaultForumLayout,
    flagsValue: flags, tagsValue: availableTags, archivedValue: archived,
    lockedValue: locked, invitableValue: invitable,
    appliedTagsValue: appliedTags)

proc channelPosition*(channelId: ChannelId;
                      position = none(int);
                      parentId = editOmit(ChannelId);
                      lockPermissions = none(bool)): ChannelPosition =
  ## Builds one guild-channel reorder entry.
  channelId.requireNonzero("channel position ID")
  if position.isSome and position.get < 0:
    raise newException(ValueError, "channel position must not be negative")
  if parentId.isSet:
    editValue(parentId).requireNonzero("channel position parent ID")
  ChannelPosition(channelIdValue: channelId, positionValue: position,
    parentIdValue: parentId, lockPermissionsValue: lockPermissions)

proc toWire(value: ForumEmoji): JsonNode =
  value.validateEmoji()
  result = newJObject()
  if value.emojiIdValue.isSome:
    result["emoji_id"] = newJString($value.emojiIdValue.get)
  else:
    result["emoji_name"] = newJString(value.emojiNameValue.get)

proc toWire(value: ForumTagCreate): JsonNode =
  value.nameValue.validateText("forum tag name", 1, 50)
  result = %*{"name": value.nameValue}
  if value.emojiValue.isSome:
    let emoji = value.emojiValue.get.toWire()
    for key, item in emoji:
      result[key] = item
  if value.moderatedValue.isSome:
    result["moderated"] = newJBool(value.moderatedValue.get)

proc toWire(value: PermissionOverwriteEdit; includeId: bool): JsonNode =
  value.validateOverwrite()
  result = newJObject()
  if includeId:
    result["id"] = newJString($value.targetIdValue)
  result["type"] = newJInt(ord(value.kindValue))
  result["allow"] = newJString(value.allowValue.toDecimal())
  result["deny"] = newJString(value.denyValue.toDecimal())

proc toWire(value: GuildChannelCreate): JsonNode =
  discard guildChannelCreate(value.nameValue, value.kindValue,
    value.positionValue, value.topicValue, value.bitrateValue,
    value.userLimitValue, value.nsfwValue, value.slowmodeValue,
    value.parentIdValue, value.overwritesValue, value.rtcRegionValue,
    value.videoQualityValue, value.autoArchiveValue,
    value.defaultReactionValue, value.defaultThreadSlowmodeValue,
    value.sortOrderValue, value.forumLayoutValue, value.tagsValue)
  result = %*{"name": value.nameValue, "type": ord(value.kindValue)}
  if value.positionValue.isSome:
    result["position"] = newJInt(value.positionValue.get)
  if value.topicValue.isSome:
    result["topic"] = newJString(value.topicValue.get)
  if value.bitrateValue.isSome:
    result["bitrate"] = newJInt(value.bitrateValue.get)
  if value.userLimitValue.isSome:
    result["user_limit"] = newJInt(value.userLimitValue.get)
  if value.nsfwValue.isSome:
    result["nsfw"] = newJBool(value.nsfwValue.get)
  if value.slowmodeValue.isSome:
    result["rate_limit_per_user"] = newJInt(value.slowmodeValue.get)
  if value.parentIdValue.isSome:
    result["parent_id"] = newJString($value.parentIdValue.get)
  if value.overwritesValue.len != 0:
    result["permission_overwrites"] = newJArray()
    for overwrite in value.overwritesValue:
      result["permission_overwrites"].add(overwrite.toWire(true))
  if value.rtcRegionValue.isSome:
    result["rtc_region"] = newJString(value.rtcRegionValue.get)
  if value.videoQualityValue.isSome:
    result["video_quality_mode"] = newJInt(ord(value.videoQualityValue.get))
  if value.autoArchiveValue.isSome:
    result["default_auto_archive_duration"] =
      newJInt(ord(value.autoArchiveValue.get))
  if value.defaultReactionValue.isSome:
    result["default_reaction_emoji"] = value.defaultReactionValue.get.toWire()
  if value.defaultThreadSlowmodeValue.isSome:
    result["default_thread_rate_limit_per_user"] =
      newJInt(value.defaultThreadSlowmodeValue.get)
  if value.sortOrderValue.isSome:
    result["default_sort_order"] = newJInt(ord(value.sortOrderValue.get))
  if value.forumLayoutValue.isSome:
    result["default_forum_layout"] = newJInt(ord(value.forumLayoutValue.get))
  if value.tagsValue.len != 0:
    result["available_tags"] = newJArray()
    for tag in value.tagsValue:
      result["available_tags"].add(tag.toWire())

template putEdit(body: JsonNode; name: string; edit: untyped;
                 encoded: untyped) =
  if edit.isClear:
    body[name] = newJNull()
  elif edit.isSet:
    let fieldValue {.inject.} = editValue(edit)
    body[name] = encoded

proc toWire(value: ChannelEdit): JsonNode =
  result = newJObject()
  if value.kindValue.isSet:
    editValue(value.kindValue).validateChannelKind()
  result.putEdit("type", value.kindValue, newJInt(ord(fieldValue)))
  if value.nameValue.isClear:
    raise newException(ValueError, "channel name cannot be cleared")
  if value.nameValue.isSet:
    editValue(value.nameValue).validateText(
      "channel name", 1, MaxChannelNameLength)
  result.putEdit("name", value.nameValue, newJString(fieldValue))
  if value.positionValue.isSet and editValue(value.positionValue) < 0:
    raise newException(ValueError, "channel position must not be negative")
  result.putEdit("position", value.positionValue, newJInt(fieldValue))
  if value.topicValue.isSet:
    editValue(value.topicValue).validateText(
      "channel topic", 0, MaxChannelTopicLength)
  result.putEdit("topic", value.topicValue, newJString(fieldValue))
  if value.bitrateValue.isSet and editValue(value.bitrateValue) < 8_000:
    raise newException(ValueError, "channel bitrate must be at least 8000")
  result.putEdit("bitrate", value.bitrateValue, newJInt(fieldValue))
  if value.userLimitValue.isSet and editValue(value.userLimitValue) < 0:
    raise newException(ValueError, "channel user limit must not be negative")
  result.putEdit("user_limit", value.userLimitValue, newJInt(fieldValue))
  result.putEdit("nsfw", value.nsfwValue, newJBool(fieldValue))
  if value.slowmodeValue.isSet:
    editValue(value.slowmodeValue).validateSlowmode("channel slowmode")
  result.putEdit("rate_limit_per_user", value.slowmodeValue,
    newJInt(fieldValue))
  if value.parentIdValue.isSet:
    editValue(value.parentIdValue).requireNonzero("channel parent ID")
  result.putEdit("parent_id", value.parentIdValue, newJString($fieldValue))
  if value.overwritesValue.isSet:
    editValue(value.overwritesValue).validateOverwrites()
  result.putEdit("permission_overwrites", value.overwritesValue,
    block:
      var items = newJArray()
      for overwrite in fieldValue:
        items.add(overwrite.toWire(true))
      items)
  result.putEdit("rtc_region", value.rtcRegionValue, newJString(fieldValue))
  result.putEdit("video_quality_mode", value.videoQualityValue,
    newJInt(ord(fieldValue)))
  result.putEdit("auto_archive_duration", value.autoArchiveValue,
    newJInt(ord(fieldValue)))
  result.putEdit("default_reaction_emoji", value.defaultReactionValue,
    fieldValue.toWire())
  if value.defaultThreadSlowmodeValue.isSet:
    editValue(value.defaultThreadSlowmodeValue).validateSlowmode(
      "default thread slowmode")
  result.putEdit("default_thread_rate_limit_per_user",
    value.defaultThreadSlowmodeValue, newJInt(fieldValue))
  result.putEdit("default_sort_order", value.sortOrderValue,
    newJInt(ord(fieldValue)))
  result.putEdit("default_forum_layout", value.forumLayoutValue,
    newJInt(ord(fieldValue)))
  if value.flagsValue.isSet and editValue(value.flagsValue) < 0:
    raise newException(ValueError, "channel flags must not be negative")
  result.putEdit("flags", value.flagsValue, newJInt(fieldValue))
  if value.tagsValue.isSet:
    editValue(value.tagsValue).validateTags()
  result.putEdit("available_tags", value.tagsValue,
    block:
      var items = newJArray()
      for tag in fieldValue:
        items.add(tag.toWire())
      items)
  result.putEdit("archived", value.archivedValue, newJBool(fieldValue))
  result.putEdit("locked", value.lockedValue, newJBool(fieldValue))
  result.putEdit("invitable", value.invitableValue, newJBool(fieldValue))
  if value.appliedTagsValue.isSet:
    let tags = editValue(value.appliedTagsValue)
    if tags.len > MaxAppliedForumTags:
      raise newException(ValueError, "a thread cannot apply more than " &
        $MaxAppliedForumTags & " forum tags")
    var seen = initHashSet[ForumTagId]()
    for tagId in tags:
      tagId.requireNonzero("applied forum tag ID")
      if tagId in seen:
        raise newException(ValueError, "applied forum tags must be unique")
      seen.incl(tagId)
  result.putEdit("applied_tags", value.appliedTagsValue,
    block:
      var items = newJArray()
      for tagId in fieldValue:
        items.add(newJString($tagId))
      items)
  if result.len == 0:
    raise newException(ValueError, "channel edit must change at least one field")

proc toWire(value: ChannelPosition): JsonNode =
  value.channelIdValue.requireNonzero("channel position ID")
  result = %*{"id": $value.channelIdValue}
  if value.positionValue.isSome:
    if value.positionValue.get < 0:
      raise newException(ValueError, "channel position must not be negative")
    result["position"] = newJInt(value.positionValue.get)
  result.putEdit("parent_id", value.parentIdValue, newJString($fieldValue))
  if value.lockPermissionsValue.isSome:
    result["lock_permissions"] = newJBool(value.lockPermissionsValue.get)

proc fetchChannel*(client: ChronosRestClient; channelId: ChannelId;
                   options = initApiCallOptions()):
                   Future[channel.Channel] {.async.} =
  ## Fetches a channel, DM, or thread under the strict REST contract.
  let raw = raw_request.initRawRequest(channel_routes.getChannel, [
    initRawParameter("channel_id", $channelId)])
  return await client.executeJson(raw, decodeChannelResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc editChannel*(client: ChronosRestClient; channelId: ChannelId;
                  edit: ChannelEdit; options = initApiCallOptions()):
                  Future[channel.Channel] {.async.} =
  ## Edits a channel or thread. `options.auditReason` is sent when present.
  let raw = raw_request.initRawRequest(channel_routes.updateChannel, [
    initRawParameter("channel_id", $channelId)], edit.toWire())
  return await client.executeJson(raw, decodeChannelResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc deleteChannel*(client: ChronosRestClient; channelId: ChannelId;
                    options = initApiCallOptions()):
                    Future[channel.Channel] {.async.} =
  ## Deletes or closes a channel and returns Discord's final channel object.
  ## The operation is not retried because its response cannot be reproduced.
  let raw = raw_request.initRawRequest(channel_routes.deleteChannel, [
    initRawParameter("channel_id", $channelId)])
  return await client.executeJson(raw, decodeChannelResponse,
    auth = darBot, meta = options.requestMeta(idNever))

proc listGuildChannels*(client: ChronosRestClient; guildId: GuildId;
                        options = initApiCallOptions()):
                        Future[seq[channel.Channel]] {.async.} =
  ## Lists the guild's channels and threads.
  let raw = raw_request.initRawRequest(guild_routes.listGuildChannels, [
    initRawParameter("guild_id", $guildId)])
  return await client.executeJsonArray(raw, decodeChannelResponse,
    auth = darBot, meta = options.requestMeta(idSafe), allowNull = true)

proc createGuildChannel*(client: ChronosRestClient; guildId: GuildId;
                         create: GuildChannelCreate;
                         options = initApiCallOptions()):
                         Future[channel.Channel] {.async.} =
  ## Creates a guild channel. Creation is intentionally not retried.
  let raw = raw_request.initRawRequest(guild_routes.createGuildChannel, [
    initRawParameter("guild_id", $guildId)], create.toWire())
  return await client.executeJson(raw, decodeChannelResponse,
    auth = darBot, meta = options.requestMeta(idNever),
    statuses = {SuccessStatus(201)})

proc reorderGuildChannels*(client: ChronosRestClient; guildId: GuildId;
                           positions: seq[ChannelPosition];
                           options = initApiCallOptions()):
                           Future[void] {.async.} =
  ## Reorders or reparents one or more guild channels.
  if positions.len == 0:
    raise newException(ValueError,
      "guild channel reorder requires at least one channel")
  var seen = initHashSet[ChannelId]()
  var body = newJArray()
  for position in positions:
    if position.channelIdValue in seen:
      raise newException(ValueError,
        "guild channel reorder IDs must be unique")
    seen.incl(position.channelIdValue)
    body.add(position.toWire())
  let raw = raw_request.initRawRequest(guild_routes.bulkUpdateGuildChannels, [
    initRawParameter("guild_id", $guildId)], body)
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc setChannelPermissionOverwrite*(client: ChronosRestClient;
                                    channelId: ChannelId;
                                    overwrite: PermissionOverwriteEdit;
                                    options = initApiCallOptions()):
                                    Future[void] {.async.} =
  ## Creates or replaces one role/member channel overwrite.
  let raw = raw_request.initRawRequest(
    channel_routes.setChannelPermissionOverwrite, [
      initRawParameter("channel_id", $channelId),
      initRawParameter("overwrite_id", $overwrite.targetIdValue),
    ], overwrite.toWire(false))
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc deleteChannelPermissionOverwriteImpl(client: ChronosRestClient;
                                          channelId: ChannelId;
                                          targetId: uint64;
                                          options: ApiCallOptions):
                                          Future[void] {.async.} =
  if targetId == 0:
    raise newException(ValueError,
      "permission overwrite target ID must be greater than zero")
  let raw = raw_request.initRawRequest(
    channel_routes.deleteChannelPermissionOverwrite, [
      initRawParameter("channel_id", $channelId),
      initRawParameter("overwrite_id", $targetId),
    ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc deleteChannelPermissionOverwrite*(client: ChronosRestClient;
                                       channelId: ChannelId; roleId: RoleId;
                                       options = initApiCallOptions()):
                                       Future[void] {.async.} =
  ## Deletes a role-targeted channel overwrite.
  await client.deleteChannelPermissionOverwriteImpl(channelId,
    roleId.toUint64, options)

proc deleteChannelPermissionOverwrite*(client: ChronosRestClient;
                                       channelId: ChannelId; userId: UserId;
                                       options = initApiCallOptions()):
                                       Future[void] {.async.} =
  ## Deletes a member-targeted channel overwrite.
  await client.deleteChannelPermissionOverwriteImpl(channelId,
    userId.toUint64, options)

proc triggerTyping*(client: ChronosRestClient; channelId: ChannelId;
                    options = initApiCallOptions()): Future[void] {.async.} =
  ## Triggers the short-lived typing indicator. The action is not retried.
  let raw = raw_request.initRawRequest(channel_routes.triggerTypingIndicator, [
    initRawParameter("channel_id", $channelId)])
  discard await client.executeChecked(raw, auth = darBot,
    meta = options.requestMeta(idNever),
    statuses = {SuccessStatus(200), SuccessStatus(204)})

proc followAnnouncementChannel*(client: ChronosRestClient;
                                sourceChannelId: ChannelId;
                                destinationChannelId: ChannelId;
                                options = initApiCallOptions()):
                                Future[FollowedChannel] {.async.} =
  ## Follows an announcement channel into a destination channel.
  let body = %*{"webhook_channel_id": $destinationChannelId}
  let raw = raw_request.initRawRequest(channel_routes.followChannel, [
    initRawParameter("channel_id", $sourceChannelId)], body)
  return await client.executeJson(raw, decodeFollowedChannel,
    auth = darBot, meta = options.requestMeta(idNever))
