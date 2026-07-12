## Semantic model for Discord guild scheduled events.

import std/[json, options]

import ./[common, user]

type
  ScheduledEventPrivacyLevel* = enum
    ## Visibility levels currently documented by Discord.
    seplGuildOnly = 2

  ScheduledEventEntityType* = enum
    ## Resource that hosts a scheduled event.
    seetStageInstance = 1
    seetVoice = 2
    seetExternal = 3

  ScheduledEventStatus* = enum
    ## Lifecycle states returned by Discord.
    sesScheduled = 1
    sesActive = 2
    sesCompleted = 3
    sesCanceled = 4

  ScheduledEventMetadata* = object
    ## Additional entity data. External events carry a location.
    location*: Option[string]

  ScheduledEvent* = object
    ## One guild scheduled event returned by REST or Gateway.
    id*: ScheduledEventId
    guildId*: GuildId
    channelId*: Option[ChannelId]
    creatorId*: Option[UserId]
    name*: string
    description*: Option[string]
    scheduledStartTime*: Timestamp
    scheduledEndTime*: Option[Timestamp]
    privacyLevel*: OpenEnum[ScheduledEventPrivacyLevel, int]
    status*: OpenEnum[ScheduledEventStatus, int]
    entityType*: OpenEnum[ScheduledEventEntityType, int]
    entityId*: Option[ScheduledEventId]
    entityMetadata*: Option[ScheduledEventMetadata]
    creator*: Option[User]
    userCount*: Option[int64]
    image*: Option[string]
    snapshot: DiscordSnapshot

proc decodeMetadata(node: JsonNode): ScheduledEventMetadata =
  let obj = ensureObject(node, "scheduled event.entity_metadata")
  result.location = optNonNullString(
    obj, "location", "scheduled event.entity_metadata")

proc decodeScheduledEvent*(node: JsonNode): ScheduledEvent =
  ## Decodes the documented Guild Scheduled Event Object and retains new fields.
  let obj = ensureObject(node, "scheduled event")
  result.id = decodeId(ScheduledEventId,
    requireField(obj, "id", "scheduled event"), "scheduled event.id")
  result.guildId = decodeId(GuildId,
    requireField(obj, "guild_id", "scheduled event"),
    "scheduled event.guild_id")
  result.channelId = reqNullableId(
    ChannelId, obj, "channel_id", "scheduled event")
  result.creatorId = if obj.hasKey("creator_id"):
      reqNullableId(UserId, obj, "creator_id", "scheduled event")
    else:
      none(UserId)
  result.name = asString(requireField(obj, "name", "scheduled event"),
    "scheduled event.name")
  result.description = if obj.hasKey("description"):
      reqNullableString(obj, "description", "scheduled event")
    else:
      none(string)
  result.scheduledStartTime = decodeTimestamp(
    requireField(obj, "scheduled_start_time", "scheduled event"),
    "scheduled event.scheduled_start_time")
  result.scheduledEndTime = reqNullableTimestamp(
    obj, "scheduled_end_time", "scheduled event")
  result.privacyLevel = decodeIntEnum(ScheduledEventPrivacyLevel,
    requireField(obj, "privacy_level", "scheduled event"),
    "scheduled event.privacy_level")
  result.status = decodeIntEnum(ScheduledEventStatus,
    requireField(obj, "status", "scheduled event"),
    "scheduled event.status")
  result.entityType = decodeIntEnum(ScheduledEventEntityType,
    requireField(obj, "entity_type", "scheduled event"),
    "scheduled event.entity_type")
  result.entityId = reqNullableId(
    ScheduledEventId, obj, "entity_id", "scheduled event")
  let metadata = requireNullable(
    obj, "entity_metadata", "scheduled event")
  if metadata.isSome:
    result.entityMetadata = some(decodeMetadata(metadata.get))
  let creator = optNonNullObject(obj, "creator", "scheduled event")
  if creator.isSome:
    result.creator = some(decodeUser(creator.get))
  result.userCount = optNonNullInt(
    obj, "user_count", "scheduled event")
  result.image = if obj.hasKey("image"):
      reqNullableString(obj, "image", "scheduled event")
    else:
      none(string)
  result.snapshot = initSnapshot(obj, [
    "id", "guild_id", "channel_id", "creator_id", "name", "description",
    "scheduled_start_time", "scheduled_end_time", "privacy_level", "status",
    "entity_type", "entity_id", "entity_metadata", "creator", "user_count",
    "image",
  ])

proc rawJson*(event: ScheduledEvent): JsonNode =
  ## Returns an owned copy of the original scheduled-event object.
  rawJson(event.snapshot)

proc unknownFields*(event: ScheduledEvent): seq[UnknownField] =
  ## Returns fields introduced after this semantic projection.
  unknownFields(event.snapshot)
