## Semantic guild-member REST operations.
##
## OAuth access tokens used to add members remain wrapped in `Secret` and are
## revealed only while constructing the outbound JSON body. List and search
## operations require the application's GUILD_MEMBERS privileged intent; that
## deployment permission is documented but intentionally not guessed locally.

import std/[json, options, sets, unicode]

import chronos

import cordnim/api/fields
import cordnim/api/internal/execute
import cordnim/api/options
import cordnim/core/secrets
import cordnim/models/member
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/guilds as guild_routes
import cordnim/rest/chronos_driver
import cordnim/rest/request

export member
export fields
export options

const
  MaxMemberPageSize* = 1_000
  MaxMemberSearchLength* = 100
  MaxMemberNickLength* = 32
  MaxMemberBioLength* = 190
  MaxAddedMemberRoles* = 250
  MaxEditedMemberRoles* = 350
  MaxMemberAccessTokenLength* = 10_240

type
  MemberListQuery* = object ## Guild-member snowflake pagination.
    limitValue: Option[int]
    afterValue: Option[UserId]

  MemberSearchQuery* = object ## Prefix search with a bounded result count.
    queryValue: string
    limitValue: Option[int]

  MemberAdd* = object ## OAuth-backed guild-member addition body.
    accessTokenValue: Secret[OAuthBearerToken]
    nickValue: Option[string]
    roleIdsValue: seq[RoleId]
    muteValue: Option[bool]
    deafValue: Option[bool]
    flagsValue: Option[int64]

  MemberEdit* = object ## Guild-member PATCH body.
    nickValue: FieldEdit[string]
    roleIdsValue: FieldEdit[seq[RoleId]]
    muteValue: FieldEdit[bool]
    deafValue: FieldEdit[bool]
    channelIdValue: FieldEdit[ChannelId]
    timeoutUntilValue: FieldEdit[string]
    flagsValue: FieldEdit[int64]

  MyMemberEdit* = object ## Current bot member-profile PATCH body.
    nickValue: FieldEdit[string]
    avatarValue: FieldEdit[string]
    bioValue: FieldEdit[string]
    bannerValue: FieldEdit[string]

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

proc validateRoles(values: openArray[RoleId]; maximum: int; label: string) =
  if values.len > maximum:
    raise newException(ValueError, label & " cannot contain more than " &
      $maximum & " roles")
  var seen = initHashSet[RoleId]()
  for roleId in values:
    roleId.requireNonzero(label & " role ID")
    if roleId in seen:
      raise newException(ValueError, label & " role IDs must be unique")
    seen.incl(roleId)

proc memberListQuery*(limit = none(int); after = none(UserId)):
                      MemberListQuery =
  ## Builds member pagination. Calling the endpoint requires GUILD_MEMBERS.
  if limit.isSome and (limit.get < 1 or limit.get > MaxMemberPageSize):
    raise newException(ValueError, "member list limit must be between 1 and " &
      $MaxMemberPageSize)
  if after.isSome:
    after.get.requireNonzero("member list cursor ID")
  MemberListQuery(limitValue: limit, afterValue: after)

proc memberSearchQuery*(query: string; limit = none(int)):
                        MemberSearchQuery =
  ## Builds a username/nickname prefix search. Requires GUILD_MEMBERS.
  query.validateText("member search query", 1, MaxMemberSearchLength)
  if limit.isSome and (limit.get < 1 or limit.get > MaxMemberPageSize):
    raise newException(ValueError, "member search limit must be between 1 and " &
      $MaxMemberPageSize)
  MemberSearchQuery(queryValue: query, limitValue: limit)

proc memberAdd*(accessToken: Secret[OAuthBearerToken];
                nick = none(string); roleIds: seq[RoleId] = @[];
                mute = none(bool); deaf = none(bool);
                flags = none(int64)): MemberAdd =
  ## Builds a member-add body from an already wrapped OAuth access token.
  if accessToken.isEmpty or accessToken.len > MaxMemberAccessTokenLength:
    raise newException(ValueError, "member OAuth access token length is invalid")
  if nick.isSome:
    nick.get.validateText("member nickname", 0, MaxMemberNickLength)
  roleIds.validateRoles(MaxAddedMemberRoles, "member add")
  if flags.isSome and flags.get < 0:
    raise newException(ValueError, "member flags must not be negative")
  MemberAdd(accessTokenValue: accessToken, nickValue: nick,
    roleIdsValue: roleIds, muteValue: mute, deafValue: deaf,
    flagsValue: flags)

proc memberAdd*(accessToken: sink string;
                nick = none(string); roleIds: seq[RoleId] = @[];
                mute = none(bool); deaf = none(bool);
                flags = none(int64)): MemberAdd =
  ## Wraps a plaintext OAuth access token immediately at the input boundary.
  memberAdd(initSecret[OAuthBearerToken](accessToken), nick, roleIds,
    mute, deaf, flags)

proc memberEdit*(nick = editOmit(string);
                 roleIds = editOmit(seq[RoleId]);
                 mute = editOmit(bool);
                 deaf = editOmit(bool);
                 channelId = editOmit(ChannelId);
                 communicationDisabledUntil = editOmit(string);
                 flags = editOmit(int64)): MemberEdit =
  ## Builds a member edit. Clear `channelId` to disconnect from voice and clear
  ## `communicationDisabledUntil` to remove a timeout.
  MemberEdit(nickValue: nick, roleIdsValue: roleIds, muteValue: mute,
    deafValue: deaf, channelIdValue: channelId,
    timeoutUntilValue: communicationDisabledUntil, flagsValue: flags)

proc myMemberEdit*(nick = editOmit(string);
                   avatar = editOmit(string);
                   bio = editOmit(string);
                   banner = editOmit(string)): MyMemberEdit =
  ## Builds an edit for the current bot's guild member profile.
  MyMemberEdit(nickValue: nick, avatarValue: avatar,
    bioValue: bio, bannerValue: banner)

func `$`*(value: MemberAdd): string =
  ## Describes the request without exposing its OAuth access token.
  discard value
  "MemberAdd(accessToken: " & redactedSecret & ")"

func repr*(value: MemberAdd): string =
  ## Uses the same token-free representation as `$`.
  $value

proc `%`*(value: MemberAdd): JsonNode =
  ## Emits a credential-free diagnostic representation.
  discard value
  %*{"access_token": redactedSecret}

proc toJsonHook*(value: MemberAdd): JsonNode =
  ## Prevents `std/jsonutils` from traversing request internals.
  %value

template putEdit(body: JsonNode; name: string; edit: untyped;
                 encoded: untyped) =
  if edit.isClear:
    body[name] = newJNull()
  elif edit.isSet:
    let fieldValue {.inject.} = editValue(edit)
    body[name] = encoded

proc roleIdsJson(values: openArray[RoleId]): JsonNode =
  result = newJArray()
  for roleId in values:
    result.add(newJString($roleId))

proc toWire(value: MemberAdd): JsonNode =
  if value.accessTokenValue.isEmpty or
      value.accessTokenValue.len > MaxMemberAccessTokenLength:
    raise newException(ValueError, "member OAuth access token length is invalid")
  value.roleIdsValue.validateRoles(MaxAddedMemberRoles, "member add")
  result = %*{"access_token": value.accessTokenValue.reveal()}
  if value.nickValue.isSome:
    value.nickValue.get.validateText("member nickname", 0, MaxMemberNickLength)
    result["nick"] = newJString(value.nickValue.get)
  if value.roleIdsValue.len != 0:
    result["roles"] = roleIdsJson(value.roleIdsValue)
  if value.muteValue.isSome:
    result["mute"] = newJBool(value.muteValue.get)
  if value.deafValue.isSome:
    result["deaf"] = newJBool(value.deafValue.get)
  if value.flagsValue.isSome:
    if value.flagsValue.get < 0:
      raise newException(ValueError, "member flags must not be negative")
    result["flags"] = newJInt(value.flagsValue.get)

proc toWire(value: MemberEdit): JsonNode =
  result = newJObject()
  if value.nickValue.isSet:
    editValue(value.nickValue).validateText(
      "member nickname", 0, MaxMemberNickLength)
  result.putEdit("nick", value.nickValue, newJString(fieldValue))
  if value.roleIdsValue.isSet:
    editValue(value.roleIdsValue).validateRoles(
      MaxEditedMemberRoles, "member edit")
  result.putEdit("roles", value.roleIdsValue, roleIdsJson(fieldValue))
  result.putEdit("mute", value.muteValue, newJBool(fieldValue))
  result.putEdit("deaf", value.deafValue, newJBool(fieldValue))
  if value.channelIdValue.isSet:
    editValue(value.channelIdValue).requireNonzero("member voice channel ID")
  result.putEdit("channel_id", value.channelIdValue, newJString($fieldValue))
  if value.timeoutUntilValue.isSet and
      not isRfc3339(editValue(value.timeoutUntilValue)):
    raise newException(ValueError,
      "member timeout must be an RFC 3339 timestamp")
  result.putEdit("communication_disabled_until", value.timeoutUntilValue,
    newJString(fieldValue))
  if value.flagsValue.isSet and editValue(value.flagsValue) < 0:
    raise newException(ValueError, "member flags must not be negative")
  result.putEdit("flags", value.flagsValue, newJInt(fieldValue))
  if result.len == 0:
    raise newException(ValueError, "member edit must change at least one field")

proc toWire(value: MyMemberEdit): JsonNode =
  result = newJObject()
  if value.nickValue.isSet:
    editValue(value.nickValue).validateText(
      "member nickname", 0, MaxMemberNickLength)
  result.putEdit("nick", value.nickValue, newJString(fieldValue))
  result.putEdit("avatar", value.avatarValue, newJString(fieldValue))
  if value.bioValue.isSet:
    editValue(value.bioValue).validateText("member bio", 0, MaxMemberBioLength)
  result.putEdit("bio", value.bioValue, newJString(fieldValue))
  result.putEdit("banner", value.bannerValue, newJString(fieldValue))
  if result.len == 0:
    raise newException(ValueError,
      "current member edit must change at least one field")

proc apply(raw: var raw_request.RawRequest; query: MemberListQuery) =
  discard memberListQuery(query.limitValue, query.afterValue)
  if query.limitValue.isSome:
    raw.addQuery("limit", $query.limitValue.get)
  if query.afterValue.isSome:
    raw.addQuery("after", $query.afterValue.get)

proc apply(raw: var raw_request.RawRequest; query: MemberSearchQuery) =
  discard memberSearchQuery(query.queryValue, query.limitValue)
  raw.addQuery("query", query.queryValue)
  if query.limitValue.isSome:
    raw.addQuery("limit", $query.limitValue.get)

proc listGuildMembers*(client: ChronosRestClient; guildId: GuildId;
                       query = memberListQuery();
                       options = initApiCallOptions()):
                       Future[seq[GuildMember]] {.async.} =
  ## Lists guild members. The application must enable GUILD_MEMBERS intent.
  var raw = raw_request.initRawRequest(guild_routes.listGuildMembers, [
    initRawParameter("guild_id", $guildId)])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeGuildMemberResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc searchGuildMembers*(client: ChronosRestClient; guildId: GuildId;
                         query: MemberSearchQuery;
                         options = initApiCallOptions()):
                         Future[seq[GuildMember]] {.async.} =
  ## Searches usernames and nicknames. Requires GUILD_MEMBERS intent.
  var raw = raw_request.initRawRequest(guild_routes.searchGuildMembers, [
    initRawParameter("guild_id", $guildId)])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeGuildMemberResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc fetchGuildMember*(client: ChronosRestClient; guildId: GuildId;
                       userId: UserId; options = initApiCallOptions()):
                       Future[GuildMember] {.async.} =
  ## Fetches one guild member.
  let raw = raw_request.initRawRequest(guild_routes.getGuildMember, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId)])
  return await client.executeJson(raw, decodeGuildMemberResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc addGuildMember*(client: ChronosRestClient; guildId: GuildId;
                     userId: UserId; create: MemberAdd;
                     options = initApiCallOptions()):
                     Future[Option[GuildMember]] {.async.} =
  ## Adds a user through OAuth. Returns none when the user was already a member.
  let raw = raw_request.initRawRequest(guild_routes.addGuildMember, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId)], create.toWire())
  return await client.executeOptionalJson(raw, decodeGuildMemberResponse,
    auth = darBot, meta = options.requestMeta(idSafe),
    statuses = {SuccessStatus(201), SuccessStatus(204)})

proc editGuildMember*(client: ChronosRestClient; guildId: GuildId;
                      userId: UserId; edit: MemberEdit;
                      options = initApiCallOptions()):
                      Future[Option[GuildMember]] {.async.} =
  ## Edits a guild member. Some Discord deployments answer with empty 204.
  let raw = raw_request.initRawRequest(guild_routes.updateGuildMember, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId)], edit.toWire())
  return await client.executeOptionalJson(raw, decodeGuildMemberResponse,
    auth = darBot, meta = options.requestMeta(idSafe),
    statuses = {SuccessStatus(200), SuccessStatus(204)})

proc editMyGuildMember*(client: ChronosRestClient; guildId: GuildId;
                        edit: MyMemberEdit; options = initApiCallOptions()):
                        Future[GuildMember] {.async.} =
  ## Edits the current bot's guild member profile.
  let raw = raw_request.initRawRequest(guild_routes.updateMyGuildMember, [
    initRawParameter("guild_id", $guildId)], edit.toWire())
  return await client.executeJson(raw, decodeGuildMemberResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc kickGuildMember*(client: ChronosRestClient; guildId: GuildId;
                      userId: UserId; options = initApiCallOptions()):
                      Future[void] {.async.} =
  ## Removes a member from the guild.
  let raw = raw_request.initRawRequest(guild_routes.deleteGuildMember, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc addGuildMemberRole*(client: ChronosRestClient; guildId: GuildId;
                         userId: UserId; roleId: RoleId;
                         options = initApiCallOptions()):
                         Future[void] {.async.} =
  ## Adds one role to a guild member.
  let raw = raw_request.initRawRequest(guild_routes.addGuildMemberRole, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId),
    initRawParameter("role_id", $roleId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc removeGuildMemberRole*(client: ChronosRestClient; guildId: GuildId;
                            userId: UserId; roleId: RoleId;
                            options = initApiCallOptions()):
                            Future[void] {.async.} =
  ## Removes one role from a guild member.
  let raw = raw_request.initRawRequest(guild_routes.deleteGuildMemberRole, [
    initRawParameter("guild_id", $guildId),
    initRawParameter("user_id", $userId),
    initRawParameter("role_id", $roleId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))
