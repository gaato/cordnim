## Semantic guild, role, ban, and prune REST operations.
##
## Mutations accept `ApiCallOptions.auditReason`. Role permissions are encoded
## as Discord decimal strings so unknown high permission bits survive writes.

import std/[json, options, sets, strutils, unicode]

import chronos

import cordnim/api/fields
import cordnim/api/internal/execute
import cordnim/api/options
import cordnim/models/guild
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/guilds as guild_routes
import cordnim/rest/chronos_driver
import cordnim/rest/request

export guild
export fields
export options

const
  MaxGuildNameLength* = 100
  MaxGuildDescriptionLength* = 300
  MaxBanPageSize* = 1_000
  MaxBulkBanUsers* = 200
  MaxDeletedMessageSeconds* = 604_800
  MaxPruneRoles* = 100

type
  DefaultMessageNotificationLevel* = enum ## Guild-wide notification default.
    dmnlAllMessages = 0
    dmnlOnlyMentions = 1

  ExplicitContentFilterLevel* = enum ## Guild media filtering policy.
    ecflDisabled = 0
    ecflMembersWithoutRoles = 1
    ecflAllMembers = 2

  GuildEdit* = object ## Validated guild PATCH body.
    nameValue: FieldEdit[string]
    descriptionValue: FieldEdit[string]
    iconValue: FieldEdit[string]
    verificationValue: FieldEdit[VerificationLevel]
    notificationsValue: FieldEdit[DefaultMessageNotificationLevel]
    contentFilterValue: FieldEdit[ExplicitContentFilterLevel]
    preferredLocaleValue: FieldEdit[string]
    afkTimeoutValue: FieldEdit[int]
    afkChannelIdValue: FieldEdit[ChannelId]
    systemChannelIdValue: FieldEdit[ChannelId]
    splashValue: FieldEdit[string]
    bannerValue: FieldEdit[string]
    systemChannelFlagsValue: FieldEdit[int64]
    featuresValue: FieldEdit[seq[string]]
    discoverySplashValue: FieldEdit[string]
    homeHeaderValue: FieldEdit[string]
    rulesChannelIdValue: FieldEdit[ChannelId]
    safetyAlertsChannelIdValue: FieldEdit[ChannelId]
    publicUpdatesChannelIdValue: FieldEdit[ChannelId]
    premiumProgressBarValue: FieldEdit[bool]

  RoleCreate* = object ## Validated role creation body.
    nameValue: Option[string]
    permissionsValue: Option[Permissions]
    colorValue: Option[int]
    colorsValue: Option[RoleColors]
    hoistValue: Option[bool]
    mentionableValue: Option[bool]
    iconValue: Option[string]
    unicodeEmojiValue: Option[string]

  RoleEdit* = object ## Validated role PATCH body.
    nameValue: FieldEdit[string]
    permissionsValue: FieldEdit[Permissions]
    colorValue: FieldEdit[int]
    colorsValue: FieldEdit[RoleColors]
    hoistValue: FieldEdit[bool]
    mentionableValue: FieldEdit[bool]
    iconValue: FieldEdit[string]
    unicodeEmojiValue: FieldEdit[string]

  RolePosition* = object ## One role hierarchy move.
    roleIdValue: RoleId
    positionValue: int

  BanQuery* = object ## Guild-ban pagination.
    limitValue: Option[int]
    beforeValue: Option[UserId]
    afterValue: Option[UserId]

  BanCreate* = object ## Single-user ban body.
    deleteMessageSecondsValue: Option[int]

  BulkBan* = object ## Multi-user ban body.
    userIdsValue: seq[UserId]
    deleteMessageSecondsValue: Option[int]

  PrunePreviewQuery* = object ## Guild prune estimate parameters.
    daysValue: Option[int]
    includeRolesValue: seq[RoleId]

  PruneRequest* = object ## Guild prune execution body.
    daysValue: Option[int]
    computePruneCountValue: Option[bool]
    includeRolesValue: seq[RoleId]

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

proc validateColor(value: int; label: string) =
  if value < 0 or value > 0xff_ff_ff:
    raise newException(ValueError, label & " must be between 0 and 16777215")

proc validateRoleColors(value: RoleColors) =
  value.primaryColor.int.validateColor("primary role color")
  if value.secondaryColor.isSome:
    value.secondaryColor.get.int.validateColor("secondary role color")
  if value.tertiaryColor.isSome:
    value.tertiaryColor.get.int.validateColor("tertiary role color")

proc validateRoleName(value: string) =
  value.validateText("role name", 1, 100)

proc validateEmoji(value: string) =
  value.validateText("role unicode emoji", 1, 100)

proc validateAfkTimeout(value: int) =
  if value notin [60, 300, 900, 1_800, 3_600]:
    raise newException(ValueError,
      "guild AFK timeout must be 60, 300, 900, 1800, or 3600 seconds")

proc validateFeatures(values: openArray[string]) =
  var seen = initHashSet[string]()
  for value in values:
    value.validateText("guild feature", 1, 256)
    if value in seen:
      raise newException(ValueError, "guild features must be unique")
    seen.incl(value)

proc guildEdit*(name = editOmit(string);
                description = editOmit(string);
                icon = editOmit(string);
                verificationLevel = editOmit(VerificationLevel);
                defaultMessageNotifications =
                  editOmit(DefaultMessageNotificationLevel);
                explicitContentFilter = editOmit(ExplicitContentFilterLevel);
                preferredLocale = editOmit(string);
                afkTimeout = editOmit(int);
                afkChannelId = editOmit(ChannelId);
                systemChannelId = editOmit(ChannelId);
                splash = editOmit(string);
                banner = editOmit(string);
                systemChannelFlags = editOmit(int64);
                features = editOmit(seq[string]);
                discoverySplash = editOmit(string);
                homeHeader = editOmit(string);
                rulesChannelId = editOmit(ChannelId);
                safetyAlertsChannelId = editOmit(ChannelId);
                publicUpdatesChannelId = editOmit(ChannelId);
                premiumProgressBarEnabled = editOmit(bool)): GuildEdit =
  ## Builds a guild edit with explicit omit/null/set behavior.
  GuildEdit(nameValue: name, descriptionValue: description,
    iconValue: icon, verificationValue: verificationLevel,
    notificationsValue: defaultMessageNotifications,
    contentFilterValue: explicitContentFilter,
    preferredLocaleValue: preferredLocale, afkTimeoutValue: afkTimeout,
    afkChannelIdValue: afkChannelId, systemChannelIdValue: systemChannelId,
    splashValue: splash, bannerValue: banner,
    systemChannelFlagsValue: systemChannelFlags, featuresValue: features,
    discoverySplashValue: discoverySplash, homeHeaderValue: homeHeader,
    rulesChannelIdValue: rulesChannelId,
    safetyAlertsChannelIdValue: safetyAlertsChannelId,
    publicUpdatesChannelIdValue: publicUpdatesChannelId,
    premiumProgressBarValue: premiumProgressBarEnabled)

proc roleCreate*(name = none(string);
                 permissions = none(Permissions);
                 color = none(int);
                 colors = none(RoleColors);
                 hoist = none(bool);
                 mentionable = none(bool);
                 icon = none(string);
                 unicodeEmoji = none(string)): RoleCreate =
  ## Builds a role. Omitting `name` lets Discord use its default role name.
  if name.isSome:
    name.get.validateRoleName()
  if color.isSome:
    color.get.validateColor("role color")
  if colors.isSome:
    colors.get.validateRoleColors()
  if color.isSome and colors.isSome:
    raise newException(ValueError,
      "role create cannot set both color and colors")
  if unicodeEmoji.isSome:
    unicodeEmoji.get.validateEmoji()
  if icon.isSome and unicodeEmoji.isSome:
    raise newException(ValueError,
      "role create cannot set both icon and unicodeEmoji")
  RoleCreate(nameValue: name, permissionsValue: permissions,
    colorValue: color, colorsValue: colors, hoistValue: hoist,
    mentionableValue: mentionable, iconValue: icon,
    unicodeEmojiValue: unicodeEmoji)

proc roleEdit*(name = editOmit(string);
               permissions = editOmit(Permissions);
               color = editOmit(int);
               colors = editOmit(RoleColors);
               hoist = editOmit(bool);
               mentionable = editOmit(bool);
               icon = editOmit(string);
               unicodeEmoji = editOmit(string)): RoleEdit =
  ## Builds a role edit. Icon and Unicode emoji can be independently cleared.
  RoleEdit(nameValue: name, permissionsValue: permissions,
    colorValue: color, colorsValue: colors, hoistValue: hoist,
    mentionableValue: mentionable, iconValue: icon,
    unicodeEmojiValue: unicodeEmoji)

proc rolePosition*(roleId: RoleId; position: int): RolePosition =
  ## Builds one role hierarchy move.
  roleId.requireNonzero("role position ID")
  if position < 0:
    raise newException(ValueError, "role position must not be negative")
  RolePosition(roleIdValue: roleId, positionValue: position)

proc banQuery*(limit = none(int); before = none(UserId);
               after = none(UserId)): BanQuery =
  ## Builds guild-ban pagination; before and after are mutually exclusive.
  if limit.isSome and (limit.get < 1 or limit.get > MaxBanPageSize):
    raise newException(ValueError, "ban list limit must be between 1 and " &
      $MaxBanPageSize)
  if before.isSome and after.isSome:
    raise newException(ValueError,
      "ban list cannot set both before and after")
  if before.isSome:
    before.get.requireNonzero("ban list before ID")
  if after.isSome:
    after.get.requireNonzero("ban list after ID")
  BanQuery(limitValue: limit, beforeValue: before, afterValue: after)

proc banCreate*(deleteMessageSeconds = none(int)): BanCreate =
  ## Builds a single-user ban request.
  if deleteMessageSeconds.isSome and
      (deleteMessageSeconds.get < 0 or
       deleteMessageSeconds.get > MaxDeletedMessageSeconds):
    raise newException(ValueError, "deleted message seconds must be between 0 " &
      "and " & $MaxDeletedMessageSeconds)
  BanCreate(deleteMessageSecondsValue: deleteMessageSeconds)

proc bulkBan*(userIds: seq[UserId]; deleteMessageSeconds = none(int)):
              BulkBan =
  ## Builds a bulk ban for 1..200 unique users.
  if userIds.len == 0 or userIds.len > MaxBulkBanUsers:
    raise newException(ValueError, "bulk ban requires between 1 and " &
      $MaxBulkBanUsers & " users")
  var seen = initHashSet[UserId]()
  for userId in userIds:
    userId.requireNonzero("bulk ban user ID")
    if userId in seen:
      raise newException(ValueError, "bulk ban user IDs must be unique")
    seen.incl(userId)
  discard banCreate(deleteMessageSeconds)
  BulkBan(userIdsValue: userIds,
    deleteMessageSecondsValue: deleteMessageSeconds)

proc validatePrune(days: Option[int]; roles: openArray[RoleId]) =
  if days.isSome and (days.get < 1 or days.get > 30):
    raise newException(ValueError, "prune days must be between 1 and 30")
  if roles.len > MaxPruneRoles:
    raise newException(ValueError, "prune cannot include more than " &
      $MaxPruneRoles & " roles")
  var seen = initHashSet[RoleId]()
  for roleId in roles:
    roleId.requireNonzero("prune role ID")
    if roleId in seen:
      raise newException(ValueError, "prune role IDs must be unique")
    seen.incl(roleId)

proc prunePreviewQuery*(days = none(int);
                        includeRoles: seq[RoleId] = @[]): PrunePreviewQuery =
  ## Builds a non-mutating guild prune estimate query.
  validatePrune(days, includeRoles)
  PrunePreviewQuery(daysValue: days, includeRolesValue: includeRoles)

proc pruneRequest*(days = none(int);
                   computePruneCount = none(bool);
                   includeRoles: seq[RoleId] = @[]): PruneRequest =
  ## Builds a guild prune execution request.
  validatePrune(days, includeRoles)
  PruneRequest(daysValue: days, computePruneCountValue: computePruneCount,
    includeRolesValue: includeRoles)

template putEdit(body: JsonNode; name: string; edit: untyped;
                 encoded: untyped) =
  if edit.isClear:
    body[name] = newJNull()
  elif edit.isSet:
    let fieldValue {.inject.} = editValue(edit)
    body[name] = encoded

proc roleColorsJson(value: RoleColors): JsonNode =
  value.validateRoleColors()
  result = %*{"primary_color": value.primaryColor}
  result["secondary_color"] = if value.secondaryColor.isSome:
    newJInt(value.secondaryColor.get) else: newJNull()
  result["tertiary_color"] = if value.tertiaryColor.isSome:
    newJInt(value.tertiaryColor.get) else: newJNull()

proc toWire(value: GuildEdit): JsonNode =
  result = newJObject()
  if value.nameValue.isClear:
    raise newException(ValueError, "guild name cannot be cleared")
  if value.nameValue.isSet:
    editValue(value.nameValue).validateText(
      "guild name", 2, MaxGuildNameLength)
  result.putEdit("name", value.nameValue, newJString(fieldValue))
  if value.descriptionValue.isSet:
    editValue(value.descriptionValue).validateText(
      "guild description", 0, MaxGuildDescriptionLength)
  result.putEdit("description", value.descriptionValue, newJString(fieldValue))
  result.putEdit("icon", value.iconValue, newJString(fieldValue))
  result.putEdit("verification_level", value.verificationValue,
    newJInt(ord(fieldValue)))
  result.putEdit("default_message_notifications", value.notificationsValue,
    newJInt(ord(fieldValue)))
  result.putEdit("explicit_content_filter", value.contentFilterValue,
    newJInt(ord(fieldValue)))
  if value.preferredLocaleValue.isSet:
    editValue(value.preferredLocaleValue).validateText(
      "preferred locale", 2, 35)
  result.putEdit("preferred_locale", value.preferredLocaleValue,
    newJString(fieldValue))
  if value.afkTimeoutValue.isSet:
    editValue(value.afkTimeoutValue).validateAfkTimeout()
  result.putEdit("afk_timeout", value.afkTimeoutValue, newJInt(fieldValue))
  for field in [value.afkChannelIdValue, value.systemChannelIdValue,
      value.rulesChannelIdValue, value.safetyAlertsChannelIdValue,
      value.publicUpdatesChannelIdValue]:
    if field.isSet:
      editValue(field).requireNonzero("guild channel ID")
  result.putEdit("afk_channel_id", value.afkChannelIdValue,
    newJString($fieldValue))
  result.putEdit("system_channel_id", value.systemChannelIdValue,
    newJString($fieldValue))
  result.putEdit("splash", value.splashValue, newJString(fieldValue))
  result.putEdit("banner", value.bannerValue, newJString(fieldValue))
  if value.systemChannelFlagsValue.isSet and
      editValue(value.systemChannelFlagsValue) < 0:
    raise newException(ValueError,
      "system channel flags must not be negative")
  result.putEdit("system_channel_flags", value.systemChannelFlagsValue,
    newJInt(fieldValue))
  if value.featuresValue.isSet:
    editValue(value.featuresValue).validateFeatures()
  result.putEdit("features", value.featuresValue,
    block:
      var items = newJArray()
      for feature in fieldValue:
        items.add(newJString(feature))
      items)
  result.putEdit("discovery_splash", value.discoverySplashValue,
    newJString(fieldValue))
  result.putEdit("home_header", value.homeHeaderValue,
    newJString(fieldValue))
  result.putEdit("rules_channel_id", value.rulesChannelIdValue,
    newJString($fieldValue))
  result.putEdit("safety_alerts_channel_id", value.safetyAlertsChannelIdValue,
    newJString($fieldValue))
  result.putEdit("public_updates_channel_id",
    value.publicUpdatesChannelIdValue, newJString($fieldValue))
  result.putEdit("premium_progress_bar_enabled",
    value.premiumProgressBarValue, newJBool(fieldValue))
  if result.len == 0:
    raise newException(ValueError, "guild edit must change at least one field")

proc toWire(value: RoleCreate): JsonNode =
  discard roleCreate(value.nameValue, value.permissionsValue,
    value.colorValue, value.colorsValue, value.hoistValue,
    value.mentionableValue, value.iconValue, value.unicodeEmojiValue)
  result = newJObject()
  if value.nameValue.isSome:
    result["name"] = newJString(value.nameValue.get)
  if value.permissionsValue.isSome:
    result["permissions"] = newJString(value.permissionsValue.get.toDecimal())
  if value.colorValue.isSome:
    result["color"] = newJInt(value.colorValue.get)
  if value.colorsValue.isSome:
    result["colors"] = value.colorsValue.get.roleColorsJson()
  if value.hoistValue.isSome:
    result["hoist"] = newJBool(value.hoistValue.get)
  if value.mentionableValue.isSome:
    result["mentionable"] = newJBool(value.mentionableValue.get)
  if value.iconValue.isSome:
    result["icon"] = newJString(value.iconValue.get)
  if value.unicodeEmojiValue.isSome:
    result["unicode_emoji"] = newJString(value.unicodeEmojiValue.get)

proc toWire(value: RoleEdit): JsonNode =
  result = newJObject()
  if value.nameValue.isSet:
    editValue(value.nameValue).validateRoleName()
  result.putEdit("name", value.nameValue, newJString(fieldValue))
  result.putEdit("permissions", value.permissionsValue,
    newJString(fieldValue.toDecimal()))
  if value.colorValue.isSet:
    editValue(value.colorValue).validateColor("role color")
  result.putEdit("color", value.colorValue, newJInt(fieldValue))
  if value.colorsValue.isSet:
    editValue(value.colorsValue).validateRoleColors()
  result.putEdit("colors", value.colorsValue, fieldValue.roleColorsJson())
  result.putEdit("hoist", value.hoistValue, newJBool(fieldValue))
  result.putEdit("mentionable", value.mentionableValue, newJBool(fieldValue))
  result.putEdit("icon", value.iconValue, newJString(fieldValue))
  if value.unicodeEmojiValue.isSet:
    editValue(value.unicodeEmojiValue).validateEmoji()
  result.putEdit("unicode_emoji", value.unicodeEmojiValue,
    newJString(fieldValue))
  if result.len == 0:
    raise newException(ValueError, "role edit must change at least one field")

proc toWire(value: RolePosition): JsonNode =
  value.roleIdValue.requireNonzero("role position ID")
  if value.positionValue < 0:
    raise newException(ValueError, "role position must not be negative")
  %*{"id": $value.roleIdValue, "position": value.positionValue}

proc toWire(value: BanCreate): JsonNode =
  discard banCreate(value.deleteMessageSecondsValue)
  result = newJObject()
  if value.deleteMessageSecondsValue.isSome:
    result["delete_message_seconds"] =
      newJInt(value.deleteMessageSecondsValue.get)

proc toWire(value: BulkBan): JsonNode =
  discard bulkBan(value.userIdsValue, value.deleteMessageSecondsValue)
  result = newJObject()
  result["user_ids"] = newJArray()
  for userId in value.userIdsValue:
    result["user_ids"].add(newJString($userId))
  if value.deleteMessageSecondsValue.isSome:
    result["delete_message_seconds"] =
      newJInt(value.deleteMessageSecondsValue.get)

proc roleIdsJson(values: openArray[RoleId]): JsonNode =
  result = newJArray()
  for roleId in values:
    result.add(newJString($roleId))

proc toWire(value: PruneRequest): JsonNode =
  validatePrune(value.daysValue, value.includeRolesValue)
  result = newJObject()
  if value.daysValue.isSome:
    result["days"] = newJInt(value.daysValue.get)
  if value.computePruneCountValue.isSome:
    result["compute_prune_count"] = newJBool(value.computePruneCountValue.get)
  if value.includeRolesValue.len != 0:
    result["include_roles"] = roleIdsJson(value.includeRolesValue)

proc apply(raw: var raw_request.RawRequest; query: BanQuery) =
  discard banQuery(query.limitValue, query.beforeValue, query.afterValue)
  if query.limitValue.isSome:
    raw.addQuery("limit", $query.limitValue.get)
  if query.beforeValue.isSome:
    raw.addQuery("before", $query.beforeValue.get)
  if query.afterValue.isSome:
    raw.addQuery("after", $query.afterValue.get)

proc apply(raw: var raw_request.RawRequest; query: PrunePreviewQuery) =
  validatePrune(query.daysValue, query.includeRolesValue)
  if query.daysValue.isSome:
    raw.addQuery("days", $query.daysValue.get)
  if query.includeRolesValue.len != 0:
    var ids: seq[string]
    for roleId in query.includeRolesValue:
      ids.add($roleId)
    raw.addQuery("include_roles", ids.join(","))

proc fetchGuild*(client: ChronosRestClient; guildId: GuildId;
                 withCounts = none(bool); options = initApiCallOptions()):
                 Future[Guild] {.async.} =
  ## Fetches a guild, optionally asking Discord for approximate counts.
  var raw = raw_request.initRawRequest(guild_routes.getGuild, [
    initRawParameter("guild_id", $guildId)])
  if withCounts.isSome:
    raw.addQuery("with_counts", $withCounts.get)
  return await client.executeJson(raw, decodeGuildResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc editGuild*(client: ChronosRestClient; guildId: GuildId; edit: GuildEdit;
                options = initApiCallOptions()): Future[Guild] {.async.} =
  ## Edits a guild. `options.auditReason` is sent when present.
  let raw = raw_request.initRawRequest(guild_routes.updateGuild, [
    initRawParameter("guild_id", $guildId)], edit.toWire())
  return await client.executeJson(raw, decodeGuildResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc listGuildRoles*(client: ChronosRestClient; guildId: GuildId;
                     options = initApiCallOptions()):
                     Future[seq[Role]] {.async.} =
  ## Lists all roles in a guild.
  let raw = raw_request.initRawRequest(guild_routes.listGuildRoles, [
    initRawParameter("guild_id", $guildId)])
  return await client.executeJsonArray(raw, decodeRoleResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc fetchGuildRole*(client: ChronosRestClient; guildId: GuildId;
                     roleId: RoleId; options = initApiCallOptions()):
                     Future[Role] {.async.} =
  ## Fetches one guild role.
  let raw = raw_request.initRawRequest(guild_routes.getGuildRole, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("role_id", $roleId)])
  return await client.executeJson(raw, decodeRoleResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc createGuildRole*(client: ChronosRestClient; guildId: GuildId;
                      create: RoleCreate; options = initApiCallOptions()):
                      Future[Role] {.async.} =
  ## Creates a guild role. Discord returns 200; creation is not retried.
  let raw = raw_request.initRawRequest(guild_routes.createGuildRole, [
    initRawParameter("guild_id", $guildId)], create.toWire())
  return await client.executeJson(raw, decodeRoleResponse,
    auth = darBot, meta = options.requestMeta(idNever))

proc editGuildRole*(client: ChronosRestClient; guildId: GuildId;
                    roleId: RoleId; edit: RoleEdit;
                    options = initApiCallOptions()): Future[Role] {.async.} =
  ## Edits one guild role.
  let raw = raw_request.initRawRequest(guild_routes.updateGuildRole, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("role_id", $roleId)], edit.toWire())
  return await client.executeJson(raw, decodeRoleResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc deleteGuildRole*(client: ChronosRestClient; guildId: GuildId;
                      roleId: RoleId; options = initApiCallOptions()):
                      Future[void] {.async.} =
  ## Deletes a guild role idempotently.
  let raw = raw_request.initRawRequest(guild_routes.deleteGuildRole, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("role_id", $roleId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc reorderGuildRoles*(client: ChronosRestClient; guildId: GuildId;
                        positions: seq[RolePosition];
                        options = initApiCallOptions()):
                        Future[seq[Role]] {.async.} =
  ## Reorders one or more unique roles.
  if positions.len == 0:
    raise newException(ValueError,
      "guild role reorder requires at least one role")
  var seen = initHashSet[RoleId]()
  var body = newJArray()
  for position in positions:
    if position.roleIdValue in seen:
      raise newException(ValueError, "guild role reorder IDs must be unique")
    seen.incl(position.roleIdValue)
    body.add(position.toWire())
  let raw = raw_request.initRawRequest(guild_routes.bulkUpdateGuildRoles, [
    initRawParameter("guild_id", $guildId)], body)
  return await client.executeJsonArray(raw, decodeRoleResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc listGuildBans*(client: ChronosRestClient; guildId: GuildId;
                    query = banQuery(); options = initApiCallOptions()):
                    Future[seq[Ban]] {.async.} =
  ## Lists guild bans with bounded snowflake pagination.
  var raw = raw_request.initRawRequest(guild_routes.listGuildBans, [
    initRawParameter("guild_id", $guildId)])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeBan,
    auth = darBot, meta = options.requestMeta(idSafe), allowNull = true)

proc fetchGuildBan*(client: ChronosRestClient; guildId: GuildId;
                    userId: UserId; options = initApiCallOptions()):
                    Future[Ban] {.async.} =
  ## Fetches one guild ban.
  let raw = raw_request.initRawRequest(guild_routes.getGuildBan, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId)])
  return await client.executeJson(raw, decodeBan,
    auth = darBot, meta = options.requestMeta(idSafe))

proc banGuildMember*(client: ChronosRestClient; guildId: GuildId;
                     userId: UserId; create = banCreate();
                     options = initApiCallOptions()): Future[void] {.async.} =
  ## Bans one user and optionally deletes recent messages.
  let raw = raw_request.initRawRequest(guild_routes.banUserFromGuild, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId)], create.toWire())
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc unbanGuildMember*(client: ChronosRestClient; guildId: GuildId;
                       userId: UserId; options = initApiCallOptions()):
                       Future[void] {.async.} =
  ## Removes one guild ban. The pinned route requires an empty JSON body.
  let raw = raw_request.initRawRequest(guild_routes.unbanUserFromGuild, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId)], newJObject())
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc bulkBanGuildMembers*(client: ChronosRestClient; guildId: GuildId;
                          request: BulkBan; options = initApiCallOptions()):
                          Future[BulkBanResult] {.async.} =
  ## Bans up to 200 users and returns per-user outcomes.
  let raw = raw_request.initRawRequest(guild_routes.bulkBanUsersFromGuild, [
    initRawParameter("guild_id", $guildId)], request.toWire())
  return await client.executeJson(raw, decodeBulkBanResult,
    auth = darBot, meta = options.requestMeta(idNever))

proc previewGuildPrune*(client: ChronosRestClient; guildId: GuildId;
                        query = prunePreviewQuery();
                        options = initApiCallOptions()):
                        Future[GuildPruneResult] {.async.} =
  ## Estimates a guild prune without mutating membership.
  var raw = raw_request.initRawRequest(guild_routes.previewPruneGuild, [
    initRawParameter("guild_id", $guildId)])
  raw.apply(query)
  return await client.executeJson(raw, decodeGuildPruneResult,
    auth = darBot, meta = options.requestMeta(idSafe))

proc pruneGuildMembers*(client: ChronosRestClient; guildId: GuildId;
                        request = pruneRequest();
                        options = initApiCallOptions()):
                        Future[GuildPruneResult] {.async.} =
  ## Executes a guild prune. The member-removal action is not retried.
  let raw = raw_request.initRawRequest(guild_routes.pruneGuild, [
    initRawParameter("guild_id", $guildId)], request.toWire())
  return await client.executeJson(raw, decodeGuildPruneResult,
    auth = darBot, meta = options.requestMeta(idNever))
