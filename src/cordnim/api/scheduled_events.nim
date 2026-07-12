## Semantic REST operations for Discord guild scheduled events.

import std/[json, options, unicode]

import chronos

import cordnim/api/[fields, options]
import cordnim/api/internal/execute
import cordnim/models/[common, scheduled_event]
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/guilds as guild_routes
import cordnim/rest/[chronos_driver, request]

export fields, options, scheduled_event

type
  ScheduledEventCreate* = object
    nameValue: string
    channelIdValue: Option[ChannelId]
    locationValue: Option[string]
    startValue: string
    endValue: Option[string]
    descriptionValue: Option[string]
    entityTypeValue: ScheduledEventEntityType

  ScheduledEventEdit* = object
    channelIdValue: FieldEdit[ChannelId]
    locationValue: FieldEdit[string]
    nameValue: Option[string]
    startValue: Option[string]
    endValue: FieldEdit[string]
    descriptionValue: FieldEdit[string]
    entityTypeValue: Option[ScheduledEventEntityType]
    statusValue: Option[ScheduledEventStatus]

proc validateText(value, label: string; minimum, maximum: int) =
  if value.validateUtf8 != -1 or value.runeLen < minimum or
      value.runeLen > maximum:
    raise newException(ValueError, label & " must contain between " &
      $minimum & " and " & $maximum & " UTF-8 characters")

proc validateTimestamp(value, label: string) =
  if not isRfc3339(value):
    raise newException(ValueError, label & " must be an RFC 3339 timestamp")

proc voiceScheduledEvent*(name: string; channelId: ChannelId;
                          scheduledStartTime: string;
                          entityType = seetVoice;
                          description = none(string)): ScheduledEventCreate =
  ## Builds a voice or stage scheduled event.
  name.validateText("scheduled event name", 1, 100)
  if channelId.toUint64 == 0:
    raise newException(ValueError, "scheduled event channel ID must be nonzero")
  if entityType notin {seetVoice, seetStageInstance}:
    raise newException(ValueError,
      "voice scheduled event requires a voice or stage entity type")
  scheduledStartTime.validateTimestamp("scheduled event start")
  if description.isSome:
    description.get.validateText("scheduled event description", 1, 1000)
  ScheduledEventCreate(nameValue: name, channelIdValue: some(channelId),
    startValue: scheduledStartTime, descriptionValue: description,
    entityTypeValue: entityType)

proc externalScheduledEvent*(name, location, scheduledStartTime,
                             scheduledEndTime: string;
                             description = none(string)):
                             ScheduledEventCreate =
  ## Builds an external event with its required location and end time.
  name.validateText("scheduled event name", 1, 100)
  location.validateText("scheduled event location", 1, 100)
  scheduledStartTime.validateTimestamp("scheduled event start")
  scheduledEndTime.validateTimestamp("scheduled event end")
  if description.isSome:
    description.get.validateText("scheduled event description", 1, 1000)
  ScheduledEventCreate(nameValue: name, locationValue: some(location),
    startValue: scheduledStartTime, endValue: some(scheduledEndTime),
    descriptionValue: description, entityTypeValue: seetExternal)

proc scheduledEventEdit*(
    channelId = editOmit(ChannelId);
    location = editOmit(string);
    name = none(string);
    scheduledStartTime = none(string);
    scheduledEndTime = editOmit(string);
    description = editOmit(string);
    entityType = none(ScheduledEventEntityType);
    status = none(ScheduledEventStatus)): ScheduledEventEdit =
  ## Builds a PATCH body while preserving omit versus explicit null.
  if channelId.isSet and channelId.editValue.toUint64 == 0:
    raise newException(ValueError, "scheduled event channel ID must be nonzero")
  if location.isSet:
    location.editValue.validateText("scheduled event location", 1, 100)
  if name.isSome:
    name.get.validateText("scheduled event name", 1, 100)
  if scheduledStartTime.isSome:
    scheduledStartTime.get.validateTimestamp("scheduled event start")
  if scheduledEndTime.isSet:
    scheduledEndTime.editValue.validateTimestamp("scheduled event end")
  if description.isSet:
    description.editValue.validateText("scheduled event description", 1, 1000)
  ScheduledEventEdit(channelIdValue: channelId, locationValue: location,
    nameValue: name, startValue: scheduledStartTime,
    endValue: scheduledEndTime, descriptionValue: description,
    entityTypeValue: entityType, statusValue: status)

proc toWire(create: ScheduledEventCreate): JsonNode =
  result = %*{
    "name": create.nameValue,
    "privacy_level": ord(seplGuildOnly),
    "scheduled_start_time": create.startValue,
    "entity_type": ord(create.entityTypeValue),
  }
  if create.channelIdValue.isSome:
    result["channel_id"] = %($create.channelIdValue.get)
  if create.locationValue.isSome:
    result["entity_metadata"] = %*{"location": create.locationValue.get}
  if create.endValue.isSome:
    result["scheduled_end_time"] = %create.endValue.get
  if create.descriptionValue.isSome:
    result["description"] = %create.descriptionValue.get

proc toWire(edit: ScheduledEventEdit): JsonNode =
  result = newJObject()
  if edit.channelIdValue.isClear:
    result["channel_id"] = newJNull()
  elif edit.channelIdValue.isSet:
    result["channel_id"] = %($edit.channelIdValue.editValue)
  if edit.locationValue.isClear:
    result["entity_metadata"] = newJNull()
  elif edit.locationValue.isSet:
    result["entity_metadata"] = %*{"location": edit.locationValue.editValue}
  if edit.nameValue.isSome:
    result["name"] = %edit.nameValue.get
  if edit.startValue.isSome:
    result["scheduled_start_time"] = %edit.startValue.get
  if edit.endValue.isClear:
    result["scheduled_end_time"] = newJNull()
  elif edit.endValue.isSet:
    result["scheduled_end_time"] = %edit.endValue.editValue
  if edit.descriptionValue.isClear:
    result["description"] = newJNull()
  elif edit.descriptionValue.isSet:
    result["description"] = %edit.descriptionValue.editValue
  if edit.entityTypeValue.isSome:
    result["entity_type"] = %ord(edit.entityTypeValue.get)
  if edit.statusValue.isSome:
    result["status"] = %ord(edit.statusValue.get)

proc listScheduledEvents*(client: ChronosRestClient; guildId: GuildId;
                          withUserCount = false;
                          options = initApiCallOptions()):
                          Future[seq[ScheduledEvent]] {.async.} =
  var raw = raw_request.initRawRequest(guild_routes.listGuildScheduledEvents, [
    initRawParameter("guild_id", $guildId)])
  if withUserCount:
    raw.addQuery("with_user_count", "true")
  return await client.executeJsonArray(raw, decodeScheduledEvent,
    auth = darBot, meta = options.requestMeta(idSafe), allowNull = true)

proc fetchScheduledEvent*(client: ChronosRestClient; guildId: GuildId;
                          eventId: ScheduledEventId;
                          options = initApiCallOptions()):
                          Future[ScheduledEvent] {.async.} =
  let raw = raw_request.initRawRequest(guild_routes.getGuildScheduledEvent, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("guild_scheduled_event_id", $eventId)])
  return await client.executeJson(raw, decodeScheduledEvent,
    auth = darBot, meta = options.requestMeta(idSafe))

proc createScheduledEvent*(client: ChronosRestClient; guildId: GuildId;
                           create: ScheduledEventCreate;
                           options = initApiCallOptions()):
                           Future[ScheduledEvent] {.async.} =
  let raw = raw_request.initRawRequest(guild_routes.createGuildScheduledEvent, [
    initRawParameter("guild_id", $guildId)], create.toWire())
  return await client.executeJson(raw, decodeScheduledEvent,
    auth = darBot, meta = options.requestMeta(idNever))

proc editScheduledEvent*(client: ChronosRestClient; guildId: GuildId;
                         eventId: ScheduledEventId; edit: ScheduledEventEdit;
                         options = initApiCallOptions()):
                         Future[ScheduledEvent] {.async.} =
  let raw = raw_request.initRawRequest(guild_routes.updateGuildScheduledEvent, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("guild_scheduled_event_id", $eventId)], edit.toWire())
  return await client.executeJson(raw, decodeScheduledEvent,
    auth = darBot, meta = options.requestMeta(idSafe))

proc deleteScheduledEvent*(client: ChronosRestClient; guildId: GuildId;
                           eventId: ScheduledEventId;
                           options = initApiCallOptions()): Future[void] {.async.} =
  let raw = raw_request.initRawRequest(guild_routes.deleteGuildScheduledEvent, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("guild_scheduled_event_id", $eventId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))
