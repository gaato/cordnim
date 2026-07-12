## Semantic thread REST operations.
##
## Archived-thread cursors remain type-safe: public/private archive listings use
## an RFC 3339 timestamp, while the current-user private archive route uses a
## thread snowflake. Forum creation supports JSON message bodies; multipart
## attachment uploads remain available through the raw escape hatch.

import std/[json, options, sets, unicode]

import chronos

import cordnim/api/channels
import cordnim/api/internal/execute
import cordnim/api/messages
import cordnim/api/options
import cordnim/models/channel as channel_model
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/channels as channel_routes
import cordnim/raw/routes/guilds as guild_routes
import cordnim/rest/chronos_driver
import cordnim/rest/request

export channel_model
export options

const
  MinArchivedThreadLimit* = 2
  MaxArchivedThreadLimit* = 100
  MinThreadMemberLimit* = 1
  MaxThreadMemberLimit* = 100

  forumSuppressEmbedsFlag = 1'i64 shl 2
  forumSuppressNotificationsFlag = 1'i64 shl 12
  forumMessageFlagMask = forumSuppressEmbedsFlag or forumSuppressNotificationsFlag

type
  TextThreadCreate* = object ## Validated text-thread creation body.
    nameValue: string
    autoArchiveValue: Option[ThreadAutoArchiveDuration]
    slowmodeValue: Option[int]
    kindValue: Option[ChannelType]
    invitableValue: Option[bool]

  ForumThreadCreate* = object ## Forum/media thread plus its starter message.
    nameValue: string
    autoArchiveValue: Option[ThreadAutoArchiveDuration]
    slowmodeValue: Option[int]
    appliedTagsValue: seq[ForumTagId]
    draftValue: MessageDraft[Legacy]
    allowedMentionsValue: AllowedMentions
    flagsValue: Option[int64]
    pollValue: Option[PollCreate]

  ArchivedThreadQuery* = object ## Timestamp cursor for channel archives.
    beforeValue: Option[string]
    limitValue: Option[int]

  MyArchivedThreadQuery* = object ## Snowflake cursor for the current user.
    beforeValue: Option[ChannelId]
    limitValue: Option[int]

  ThreadMemberQuery* = object ## Thread-member expansion and pagination.
    withMemberValue: Option[bool]
    afterValue: Option[UserId]
    limitValue: Option[int]

  ForumV2Thread* = object ## Forum thread whose starter is Components V2.
    thread*: channel_model.Channel ## Created forum thread.
    starter*: Message ## Starter message after the V2 upgrade.

  ForumV2UpgradeError* = object of CatchableError
    ## The forum thread was created but its starter could not be upgraded.
    threadId*: ChannelId ## Created thread that remains visible.
    starterMessageId*: MessageId ## Legacy starter requiring recovery.

proc validateName(name: string) =
  if name.validateUtf8 != -1:
    raise newException(ValueError, "thread name must be valid UTF-8")
  let length = name.runeLen
  if length < 1 or length > MaxChannelNameLength:
    raise newException(ValueError, "thread name must contain between 1 and " &
      $MaxChannelNameLength & " characters")

proc validateSlowmode(value: Option[int]) =
  if value.isSome and
      (value.get < 0 or value.get > MaxChannelSlowmodeSeconds):
    raise newException(ValueError, "thread slowmode must be between 0 and " &
      $MaxChannelSlowmodeSeconds & " seconds")

proc validateThreadKind(kind: ChannelType) =
  if ord(kind) notin [10, 11, 12]:
    raise newException(ValueError,
      "standalone thread type must be announcement, public, or private")

proc validateAppliedTags(tags: openArray[ForumTagId]) =
  if tags.len > MaxAppliedForumTags:
    raise newException(ValueError, "a forum thread cannot apply more than " &
      $MaxAppliedForumTags & " tags")
  var seen = initHashSet[ForumTagId]()
  for tagId in tags:
    if tagId.toUint64 == 0:
      raise newException(ValueError,
        "applied forum tag ID must be greater than zero")
    if tagId in seen:
      raise newException(ValueError, "applied forum tags must be unique")
    seen.incl(tagId)

proc threadFromMessage*(name: string;
                        autoArchiveDuration =
                          none(ThreadAutoArchiveDuration);
                        rateLimitPerUser = none(int)): TextThreadCreate =
  ## Builds a thread created from an existing message.
  name.validateName()
  rateLimitPerUser.validateSlowmode()
  TextThreadCreate(nameValue: name,
    autoArchiveValue: autoArchiveDuration, slowmodeValue: rateLimitPerUser)

proc standaloneThread*(name: string;
                       kind = ctPublicThread;
                       autoArchiveDuration =
                         none(ThreadAutoArchiveDuration);
                       rateLimitPerUser = none(int);
                       invitable = none(bool)): TextThreadCreate =
  ## Builds a standalone public/private/announcement thread.
  name.validateName()
  kind.validateThreadKind()
  rateLimitPerUser.validateSlowmode()
  if invitable.isSome and kind != ctPrivateThread:
    raise newException(ValueError,
      "invitable is only valid for a private thread")
  TextThreadCreate(nameValue: name,
    autoArchiveValue: autoArchiveDuration, slowmodeValue: rateLimitPerUser,
    kindValue: some(kind), invitableValue: invitable)

proc forumThread*(name: string; message: MessageDraft[Legacy];
                  autoArchiveDuration = none(ThreadAutoArchiveDuration);
                  rateLimitPerUser = none(int);
                  appliedTags: seq[ForumTagId] = @[];
                  allowedMentions = initAllowedMentions();
                  flags = none(int64);
                  poll = none(PollCreate)): ForumThreadCreate =
  ## Builds a JSON-only forum/media thread and starter message.
  name.validateName()
  rateLimitPerUser.validateSlowmode()
  appliedTags.validateAppliedTags()
  if flags.isSome and
      (flags.get < 0 or (flags.get and not forumMessageFlagMask) != 0):
    raise newException(ValueError,
      "forum starter message contains unsupported flag bits")
  let draftJson = message.toJson()
  if draftJson.len == 0 and poll.isNone:
    raise newException(ValueError,
      "forum starter message must contain content, embeds, stickers, " &
      "components, or a poll")
  ForumThreadCreate(nameValue: name,
    autoArchiveValue: autoArchiveDuration, slowmodeValue: rateLimitPerUser,
    appliedTagsValue: appliedTags, draftValue: message,
    allowedMentionsValue: allowedMentions, flagsValue: flags,
    pollValue: poll)

proc archivedThreadQuery*(before = none(string); limit = none(int)):
                          ArchivedThreadQuery =
  ## Builds pagination for public/private archived-thread listings.
  if before.isSome and not isRfc3339(before.get):
    raise newException(ValueError,
      "archived thread cursor must be an RFC 3339 timestamp")
  if limit.isSome and
      (limit.get < MinArchivedThreadLimit or limit.get > MaxArchivedThreadLimit):
    raise newException(ValueError, "archived thread limit must be between " &
      $MinArchivedThreadLimit & " and " & $MaxArchivedThreadLimit)
  ArchivedThreadQuery(beforeValue: before, limitValue: limit)

proc myArchivedThreadQuery*(before = none(ChannelId); limit = none(int)):
                            MyArchivedThreadQuery =
  ## Builds pagination for the current user's private archived threads.
  if before.isSome and before.get.toUint64 == 0:
    raise newException(ValueError,
      "archived thread cursor ID must be greater than zero")
  if limit.isSome and
      (limit.get < MinArchivedThreadLimit or limit.get > MaxArchivedThreadLimit):
    raise newException(ValueError, "archived thread limit must be between " &
      $MinArchivedThreadLimit & " and " & $MaxArchivedThreadLimit)
  MyArchivedThreadQuery(beforeValue: before, limitValue: limit)

proc threadMemberQuery*(withMember = none(bool);
                        after = none(UserId);
                        limit = none(int)): ThreadMemberQuery =
  ## Builds a member-list query. `withMember` requires the GUILD_MEMBERS intent.
  if after.isSome and after.get.toUint64 == 0:
    raise newException(ValueError,
      "thread member cursor ID must be greater than zero")
  if limit.isSome and
      (limit.get < MinThreadMemberLimit or limit.get > MaxThreadMemberLimit):
    raise newException(ValueError, "thread member limit must be between " &
      $MinThreadMemberLimit & " and " & $MaxThreadMemberLimit)
  ThreadMemberQuery(withMemberValue: withMember,
    afterValue: after, limitValue: limit)

proc toWire(value: TextThreadCreate; fromMessage: bool): JsonNode =
  value.nameValue.validateName()
  value.slowmodeValue.validateSlowmode()
  if fromMessage and (value.kindValue.isSome or value.invitableValue.isSome):
    raise newException(ValueError,
      "a message thread cannot set type or invitable")
  if not fromMessage:
    if value.kindValue.isNone:
      raise newException(ValueError, "standalone thread type is required")
    value.kindValue.get.validateThreadKind()
    if value.invitableValue.isSome and value.kindValue.get != ctPrivateThread:
      raise newException(ValueError,
        "invitable is only valid for a private thread")
  result = %*{"name": value.nameValue}
  if value.autoArchiveValue.isSome:
    result["auto_archive_duration"] =
      newJInt(ord(value.autoArchiveValue.get))
  if value.slowmodeValue.isSome:
    result["rate_limit_per_user"] = newJInt(value.slowmodeValue.get)
  if value.kindValue.isSome:
    result["type"] = newJInt(ord(value.kindValue.get))
  if value.invitableValue.isSome:
    result["invitable"] = newJBool(value.invitableValue.get)

proc starterMessage(value: ForumThreadCreate): JsonNode =
  result = value.draftValue.toJson()
  result["allowed_mentions"] = value.allowedMentionsValue.toJson()
  if value.flagsValue.isSome:
    if value.flagsValue.get < 0 or
        (value.flagsValue.get and not forumMessageFlagMask) != 0:
      raise newException(ValueError,
        "forum starter message contains unsupported flag bits")
    result["flags"] = newJInt(value.flagsValue.get)
  if value.pollValue.isSome:
    result["poll"] = value.pollValue.get.toJson()
  if result.len == 1 and result.hasKey("allowed_mentions"):
    raise newException(ValueError,
      "forum starter message must contain content, embeds, stickers, " &
      "components, or a poll")

proc toWire(value: ForumThreadCreate): JsonNode =
  value.nameValue.validateName()
  value.slowmodeValue.validateSlowmode()
  value.appliedTagsValue.validateAppliedTags()
  result = %*{"name": value.nameValue, "message": value.starterMessage()}
  if value.autoArchiveValue.isSome:
    result["auto_archive_duration"] =
      newJInt(ord(value.autoArchiveValue.get))
  if value.slowmodeValue.isSome:
    result["rate_limit_per_user"] = newJInt(value.slowmodeValue.get)
  if value.appliedTagsValue.len != 0:
    result["applied_tags"] = newJArray()
    for tagId in value.appliedTagsValue:
      result["applied_tags"].add(newJString($tagId))

proc apply(raw: var raw_request.RawRequest; query: ArchivedThreadQuery) =
  discard archivedThreadQuery(query.beforeValue, query.limitValue)
  if query.beforeValue.isSome:
    raw.addQuery("before", query.beforeValue.get)
  if query.limitValue.isSome:
    raw.addQuery("limit", $query.limitValue.get)

proc apply(raw: var raw_request.RawRequest; query: MyArchivedThreadQuery) =
  discard myArchivedThreadQuery(query.beforeValue, query.limitValue)
  if query.beforeValue.isSome:
    raw.addQuery("before", $query.beforeValue.get)
  if query.limitValue.isSome:
    raw.addQuery("limit", $query.limitValue.get)

proc apply(raw: var raw_request.RawRequest; query: ThreadMemberQuery) =
  discard threadMemberQuery(query.withMemberValue,
    query.afterValue, query.limitValue)
  if query.withMemberValue.isSome:
    raw.addQuery("with_member", $query.withMemberValue.get)
  if query.afterValue.isSome:
    raw.addQuery("after", $query.afterValue.get)
  if query.limitValue.isSome:
    raw.addQuery("limit", $query.limitValue.get)

proc createThreadFromMessage*(client: ChronosRestClient;
                              channelId: ChannelId; messageId: MessageId;
                              create: TextThreadCreate;
                              options = initApiCallOptions()):
                              Future[channel_model.Channel] {.async.} =
  ## Creates a thread from one existing message.
  let raw = raw_request.initRawRequest(channel_routes.createThreadFromMessage, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId)], create.toWire(true))
  return await client.executeJson(raw, decodeChannelResponse,
    auth = darBot, meta = options.requestMeta(idNever),
    statuses = {SuccessStatus(201)})

proc createStandaloneThread*(client: ChronosRestClient;
                             channelId: ChannelId; create: TextThreadCreate;
                             options = initApiCallOptions()):
                             Future[channel_model.Channel] {.async.} =
  ## Creates a standalone text thread.
  let raw = raw_request.initRawRequest(channel_routes.createThread, [
    initRawParameter("channel_id", $channelId)], create.toWire(false))
  return await client.executeJson(raw, decodeChannelResponse,
    auth = darBot, meta = options.requestMeta(idNever),
    statuses = {SuccessStatus(201)})

proc createForumThread*(client: ChronosRestClient;
                        channelId: ChannelId; create: ForumThreadCreate;
                        options = initApiCallOptions()):
                        Future[channel_model.Channel] {.async.} =
  ## Creates a forum/media thread with a JSON starter message.
  let raw = raw_request.initRawRequest(channel_routes.createThread, [
    initRawParameter("channel_id", $channelId)], create.toWire())
  return await client.executeJson(raw, decodeChannelResponse,
    auth = darBot, meta = options.requestMeta(idNever),
    statuses = {SuccessStatus(201)})

proc createForumThreadV2*(client: ChronosRestClient;
                          channelId: ChannelId; name: string;
                          draft: MessageDraft[V2];
                          placeholder = "(preparing...)";
                          autoArchiveDuration =
                            none(ThreadAutoArchiveDuration);
                          rateLimitPerUser = none(int);
                          appliedTags: seq[ForumTagId] = @[];
                          allowedMentions = initAllowedMentions();
                          options = initApiCallOptions()):
                          Future[ForumV2Thread] {.async.} =
  ## Creates the endpoint-required legacy starter, then upgrades it to V2.
  ##
  ## Discord does not accept the Components V2 flag in a forum create starter.
  ## If the second request fails, `ForumV2UpgradeError` carries both identities
  ## needed to recover or delete the partial thread without searching.
  if placeholder.len == 0:
    raise newException(ValueError,
      "forum V2 placeholder must not be empty")
  let thread = await client.createForumThread(channelId,
    forumThread(name, legacyMessage(placeholder),
      autoArchiveDuration = autoArchiveDuration,
      rateLimitPerUser = rateLimitPerUser,
      appliedTags = appliedTags,
      allowedMentions = initAllowedMentions()), options)
  if thread.lastMessageId.isNone:
    let error = newException(ForumV2UpgradeError,
      "forum thread response omitted its starter message ID")
    error.threadId = thread.id
    raise error
  let starterId = thread.lastMessageId.get
  try:
    let starter = await client.upgradeMessageToV2(
      MessageHandle[Legacy](channelId: thread.id, messageId: starterId),
      v2Edit(draft.v2.children, allowedMentions = allowedMentions), options)
    return ForumV2Thread(thread: thread, starter: starter)
  except CatchableError:
    let error = newException(ForumV2UpgradeError,
      "forum thread was created but its starter V2 upgrade failed")
    error.threadId = thread.id
    error.starterMessageId = starterId
    raise error

proc listActiveGuildThreads*(client: ChronosRestClient; guildId: GuildId;
                             options = initApiCallOptions()):
                             Future[ThreadListing] {.async.} =
  ## Lists all active threads visible in a guild.
  let raw = raw_request.initRawRequest(guild_routes.getActiveGuildThreads, [
    initRawParameter("guild_id", $guildId)])
  return await client.executeJson(raw, decodeThreadListing,
    auth = darBot, meta = options.requestMeta(idSafe))

proc listPublicArchivedThreads*(client: ChronosRestClient;
                                channelId: ChannelId;
                                query = archivedThreadQuery();
                                options = initApiCallOptions()):
                                Future[ThreadListing] {.async.} =
  ## Lists public archived threads using a timestamp cursor.
  var raw = raw_request.initRawRequest(
    channel_routes.listPublicArchivedThreads, [
      initRawParameter("channel_id", $channelId)])
  raw.apply(query)
  return await client.executeJson(raw, decodeThreadListing,
    auth = darBot, meta = options.requestMeta(idSafe))

proc listPrivateArchivedThreads*(client: ChronosRestClient;
                                 channelId: ChannelId;
                                 query = archivedThreadQuery();
                                 options = initApiCallOptions()):
                                 Future[ThreadListing] {.async.} =
  ## Lists private archived threads using a timestamp cursor.
  var raw = raw_request.initRawRequest(
    channel_routes.listPrivateArchivedThreads, [
      initRawParameter("channel_id", $channelId)])
  raw.apply(query)
  return await client.executeJson(raw, decodeThreadListing,
    auth = darBot, meta = options.requestMeta(idSafe))

proc listMyPrivateArchivedThreads*(client: ChronosRestClient;
                                   channelId: ChannelId;
                                   query = myArchivedThreadQuery();
                                   options = initApiCallOptions()):
                                   Future[ThreadListing] {.async.} =
  ## Lists the current user's private archived threads using a snowflake cursor.
  var raw = raw_request.initRawRequest(
    channel_routes.listMyPrivateArchivedThreads, [
      initRawParameter("channel_id", $channelId)])
  raw.apply(query)
  return await client.executeJson(raw, decodeThreadListing,
    auth = darBot, meta = options.requestMeta(idSafe))

proc listThreadMembers*(client: ChronosRestClient; threadId: ChannelId;
                        query = threadMemberQuery();
                        options = initApiCallOptions()):
                        Future[seq[ThreadMember]] {.async.} =
  ## Lists thread members. Expanded guild members require GUILD_MEMBERS intent.
  var raw = raw_request.initRawRequest(channel_routes.listThreadMembers, [
    initRawParameter("channel_id", $threadId)])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeThreadMemberResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc fetchThreadMember*(client: ChronosRestClient; threadId: ChannelId;
                        userId: UserId; withMember = none(bool);
                        options = initApiCallOptions()):
                        Future[ThreadMember] {.async.} =
  ## Fetches one thread member, optionally expanding its guild member.
  var raw = raw_request.initRawRequest(channel_routes.getThreadMember, [
    initRawParameter("channel_id", $threadId),
    initRawParameter("user_id", $userId)])
  if withMember.isSome:
    raw.addQuery("with_member", $withMember.get)
  return await client.executeJson(raw, decodeThreadMemberResponse,
    auth = darBot, meta = options.requestMeta(idSafe))

proc joinThread*(client: ChronosRestClient; threadId: ChannelId;
                 options = initApiCallOptions()): Future[void] {.async.} =
  ## Adds the current user to a thread.
  let raw = raw_request.initRawRequest(channel_routes.joinThread, [
    initRawParameter("channel_id", $threadId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc leaveThread*(client: ChronosRestClient; threadId: ChannelId;
                  options = initApiCallOptions()): Future[void] {.async.} =
  ## Removes the current user from a thread.
  let raw = raw_request.initRawRequest(channel_routes.leaveThread, [
    initRawParameter("channel_id", $threadId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc addThreadMember*(client: ChronosRestClient; threadId: ChannelId;
                      userId: UserId; options = initApiCallOptions()):
                      Future[void] {.async.} =
  ## Adds one guild member to a thread.
  let raw = raw_request.initRawRequest(channel_routes.addThreadMember, [
    initRawParameter("channel_id", $threadId),
    initRawParameter("user_id", $userId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc removeThreadMember*(client: ChronosRestClient; threadId: ChannelId;
                         userId: UserId; options = initApiCallOptions()):
                         Future[void] {.async.} =
  ## Removes one guild member from a thread.
  let raw = raw_request.initRawRequest(channel_routes.deleteThreadMember, [
    initRawParameter("channel_id", $threadId),
    initRawParameter("user_id", $userId)])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))
