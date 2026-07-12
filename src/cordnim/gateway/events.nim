## Handler-facing semantic projections of Discord Gateway dispatch events.
##
## The shard runtime deliberately queues the raw `DispatchEvent` representation:
## it is small, preserves forward compatibility, and keeps decoding work off the
## unique Gateway reader.  `decodeGatewayEvent` is the boundary above that queue.
## It validates documented event shapes, returns semantic resource models where
## Discord sends a complete object, and retains an explicit raw branch for event
## names this version does not know yet.

import std/[json, options]

import chronos

import cordnim/core/[fields, ids, open_enums]
import cordnim/models/[channel, common, guild, member, message, monetization,
  role, user]

import ./[dispatch_runtime, session]

type
  GatewayEventKind* = enum ## Dispatch variants decoded by this module.
    gekReady, ## A new Gateway session became ready.
    gekResumed, ## A prior Gateway session resumed.
    gekGuildCreate, ## A guild became available, or remained unavailable.
    gekGuildUpdate, ## A guild resource changed.
    gekGuildDelete, ## A guild became unavailable or was removed.
    gekChannelCreate, ## A guild channel was created.
    gekChannelUpdate, ## A guild channel was updated.
    gekChannelDelete, ## A guild channel was deleted.
    gekThreadCreate, ## A thread was created or became visible.
    gekThreadUpdate, ## A thread was updated.
    gekThreadDelete, ## A thread was deleted.
    gekGuildMemberAdd, ## A member joined a guild.
    gekGuildMemberUpdate, ## A member changed without a full member response.
    gekGuildMemberRemove, ## A member left or was removed.
    gekGuildRoleCreate, ## A role was created.
    gekGuildRoleUpdate, ## A role was updated.
    gekGuildRoleDelete, ## A role was deleted.
    gekMessageCreate, ## A message was created.
    gekMessageUpdate, ## A message was partially updated.
    gekMessageDelete, ## One message was deleted.
    gekMessageDeleteBulk, ## Several messages were deleted.
    gekMessageReactionAdd, ## A reaction was added.
    gekMessageReactionRemove, ## A reaction was removed.
    gekMessageReactionRemoveAll, ## Every reaction was removed.
    gekMessageReactionRemoveEmoji, ## One emoji tally was removed.
    gekMessagePollVoteAdd, ## A user selected a poll answer.
    gekMessagePollVoteRemove, ## A user removed a poll answer selection.
    gekWebhooksUpdate, ## Webhooks in a channel changed.
    gekEntitlementCreate, ## An entitlement was created.
    gekEntitlementUpdate, ## An entitlement was updated.
    gekEntitlementDelete, ## An entitlement was deleted.
    gekSubscriptionCreate, ## A subscription was created.
    gekSubscriptionUpdate, ## A subscription was updated.
    gekSubscriptionDelete, ## A subscription was deleted.
    gekUnknown ## A future event retained through the explicit raw escape.

  ReadyUnavailableGuild* = object ## Guild stub carried by `READY`.
    id*: GuildId ## Unavailable guild identity.
    unavailable*: bool ## Always true for a valid READY guild stub.

  ReadyApplication* = object ## Application identity carried by `READY`.
    id*: ApplicationId ## Current application identity.
    flags*: int64 ## Application flag bits sent by the Gateway.

  ReadyShard* = object ## Optional shard tuple echoed by `READY`.
    id*: ShardId ## Zero-based shard identity.
    total*: uint16 ## Positive total shard count.

  ReadyEvent* = object ## Initial session state from Discord.
    version*: int64 ## Gateway protocol version.
    user*: User ## Bot user associated with the session.
    guilds*: seq[ReadyUnavailableGuild] ## Initially unavailable guild stubs.
    sessionId*: string ## Non-empty resumable session identity.
    resumeGatewayUrl*: string ## URL Discord supplied for Resume.
    shard*: Option[ReadyShard] ## Shard tuple when sharding is enabled.
    application*: ReadyApplication ## Current application identity and flags.

  GuildCreateEvent* = object ## Available or unavailable GUILD_CREATE payload.
    case unavailable*: bool ## Selects the unavailable stub or full guild.
    of true:
      guildId*: GuildId ## Guild affected by an outage.
    of false:
      guild*: Guild ## Complete available guild resource.
      joinedAt*: Timestamp ## When the current bot joined the guild.
      large*: bool ## Whether Discord considers the guild large.
      memberCount*: int64 ## Total guild member count.

  GuildDeleteEvent* = object ## GUILD_DELETE identity and outage signal.
    id*: GuildId ## Deleted or unavailable guild.
    unavailable*: Option[bool] ## True for outage; absent when removed.

  ThreadDeleteEvent* = object ## Documented subset sent for THREAD_DELETE.
    id*: ChannelId ## Deleted thread identity.
    guildId*: GuildId ## Owning guild.
    parentId*: ChannelId ## Parent channel.
    kind*: OpenEnum[ChannelType, int] ## Thread channel type.

  GuildMemberUpdateEvent* = object ## Dedicated Gateway member update shape.
    guildId*: GuildId ## Owning guild.
    roles*: seq[RoleId] ## Current role identities.
    user*: User ## Updated user projection.
    nick*: DiscordField[string] ## Optional nullable guild nickname.
    avatar*: Option[string] ## Required nullable guild avatar hash.
    banner*: Option[string] ## Required nullable guild banner hash.
    joinedAt*: Option[Timestamp] ## Required nullable join time.
    premiumSince*: DiscordField[Timestamp] ## Optional nullable boost time.
    deaf*: DiscordField[bool] ## Optional voice-deafened state.
    mute*: DiscordField[bool] ## Optional voice-muted state.
    pending*: DiscordField[bool] ## Optional screening state.
    communicationDisabledUntil*: DiscordField[Timestamp] ## Optional nullable
      ## timeout expiry.

  GuildMemberAddEvent* = object ## Full member plus its Gateway guild identity.
    guildId*: GuildId ## Guild the member joined.
    member*: GuildMember ## Full member object sent by Discord.

  GuildMemberRemoveEvent* = object ## Member removal identity.
    guildId*: GuildId ## Guild the user left.
    user*: User ## User who left or was removed.

  GuildRoleEvent* = object ## Role create/update wrapper.
    guildId*: GuildId ## Owning guild.
    role*: Role ## Created or updated role.

  GuildRoleDeleteEvent* = object ## Role deletion identity.
    guildId*: GuildId ## Owning guild.
    roleId*: RoleId ## Deleted role.

  MessageUpdateEvent* = object ## Stable fields from partial MESSAGE_UPDATE.
    id*: MessageId ## Updated message.
    channelId*: ChannelId ## Channel containing the message.
    guildId*: Option[GuildId] ## Guild, when the message is guild-scoped.
    webhookId*: DiscordField[WebhookId] ## Webhook identity, when sent.
    author*: DiscordField[MessageAuthor] ## User or webhook author, when sent.
    content*: DiscordField[string] ## Message content, when sent.
    editedTimestamp*: DiscordField[Timestamp] ## Absent, null, or edit time.
    pinned*: DiscordField[bool] ## Pin state, when sent.
    flags*: DiscordField[int64] ## Message flags, when sent.
    snapshot: DiscordSnapshot ## Lossless partial update evidence.

  MessageDeleteEvent* = object ## One deleted message identity.
    id*: MessageId ## Deleted message.
    channelId*: ChannelId ## Channel containing the message.
    guildId*: Option[GuildId] ## Guild, when guild-scoped.

  MessageDeleteBulkEvent* = object ## Bulk-deleted message identities.
    ids*: seq[MessageId] ## Non-empty unique deleted message ids.
    channelId*: ChannelId ## Channel containing the messages.
    guildId*: Option[GuildId] ## Guild, when guild-scoped.

  MessageReactionEvent* = object ## Shared add/remove reaction identity.
    userId*: UserId ## User who changed the reaction.
    channelId*: ChannelId ## Channel containing the message.
    messageId*: MessageId ## Message whose reaction changed.
    guildId*: Option[GuildId] ## Guild, when guild-scoped.
    emoji*: PartialEmoji ## Emoji whose tally changed.
    member*: Option[GuildMember] ## Reacting member, on guild reaction adds.
    messageAuthorId*: Option[UserId] ## Message author, when Discord supplied it.
    burst*: bool ## Whether this was a super reaction.
    burstColors*: seq[string] ## Super-reaction colors, when supplied.
    reactionType*: int64 ## Discord reaction type wire value.
    snapshot: DiscordSnapshot ## Lossless reaction event evidence.

  MessageReactionRemoveAllEvent* = object ## All-reaction removal identity.
    channelId*: ChannelId ## Channel containing the message.
    messageId*: MessageId ## Message whose reactions were removed.
    guildId*: Option[GuildId] ## Guild, when guild-scoped.

  MessageReactionRemoveEmojiEvent* = object ## One emoji-tally removal.
    channelId*: ChannelId ## Channel containing the message.
    messageId*: MessageId ## Message whose emoji tally was removed.
    guildId*: Option[GuildId] ## Guild, when guild-scoped.
    emoji*: PartialEmoji ## Removed emoji.

  MessagePollVoteEvent* = object ## Poll answer selection identity.
    userId*: UserId ## User who changed their vote.
    channelId*: ChannelId ## Channel containing the poll.
    messageId*: MessageId ## Poll message.
    guildId*: Option[GuildId] ## Guild, when guild-scoped.
    answerId*: int64 ## Poll answer identifier.

  WebhooksUpdateEvent* = object ## Channel whose webhook set changed.
    guildId*: GuildId ## Owning guild.
    channelId*: ChannelId ## Channel whose webhooks changed.

  UnknownGatewayEvent* = object ## Explicit forward-compatible raw branch.
    name*: string ## Unrecognized Discord event name.
    dataValue: JsonNode ## Owned raw `d` value; may contain sensitive data.

  GatewayEvent* = object ## Typed event plus ingress metadata.
    shardId*: ShardId ## Source shard.
    sequence*: GatewaySequence ## Resume sequence.
    partitionKey*: uint64 ## Dispatch ordering key.
    receivedAtMs*: int64 ## Original monotonic ingress time.
    case kind*: GatewayEventKind
    of gekReady:
      ready*: ReadyEvent
    of gekResumed:
      discard
    of gekGuildCreate:
      guildCreate*: GuildCreateEvent
    of gekGuildUpdate:
      guildUpdate*: Guild
    of gekGuildDelete:
      guildDelete*: GuildDeleteEvent
    of gekChannelCreate, gekChannelUpdate, gekChannelDelete, gekThreadCreate,
        gekThreadUpdate:
      channel*: channel.Channel
    of gekThreadDelete:
      threadDelete*: ThreadDeleteEvent
    of gekGuildMemberAdd:
      memberAdded*: GuildMemberAddEvent
    of gekGuildMemberUpdate:
      memberUpdated*: GuildMemberUpdateEvent
    of gekGuildMemberRemove:
      memberRemoved*: GuildMemberRemoveEvent
    of gekGuildRoleCreate, gekGuildRoleUpdate:
      guildRole*: GuildRoleEvent
    of gekGuildRoleDelete:
      guildRoleDelete*: GuildRoleDeleteEvent
    of gekMessageCreate:
      messageCreated*: Message
    of gekMessageUpdate:
      messageUpdated*: MessageUpdateEvent
    of gekMessageDelete:
      messageDeleted*: MessageDeleteEvent
    of gekMessageDeleteBulk:
      messagesDeleted*: MessageDeleteBulkEvent
    of gekMessageReactionAdd, gekMessageReactionRemove:
      reaction*: MessageReactionEvent
    of gekMessageReactionRemoveAll:
      reactionsRemoved*: MessageReactionRemoveAllEvent
    of gekMessageReactionRemoveEmoji:
      reactionEmojiRemoved*: MessageReactionRemoveEmojiEvent
    of gekMessagePollVoteAdd, gekMessagePollVoteRemove:
      pollVote*: MessagePollVoteEvent
    of gekWebhooksUpdate:
      webhooksUpdated*: WebhooksUpdateEvent
    of gekEntitlementCreate, gekEntitlementUpdate, gekEntitlementDelete:
      entitlement*: Entitlement
    of gekSubscriptionCreate, gekSubscriptionUpdate, gekSubscriptionDelete:
      subscription*: Subscription
    of gekUnknown:
      unknown*: UnknownGatewayEvent

  TypedGatewayEventHandler* = proc(event: GatewayEvent): Future[void] {.
    closure, gcsafe, raises: [].} ## Async handler for one decoded dispatch.

proc strictOptional(obj: JsonNode; name, owner: string): Option[JsonNode] =
  if not obj.hasKey(name):
    return none(JsonNode)
  if obj[name].kind == JNull:
    raiseDecode(owner & "." & name & " must not be null")
  some(obj[name])

proc optionalId[Kind](idType: typedesc[Id[Kind]]; obj: JsonNode;
                      name, owner: string): Option[Id[Kind]] =
  let value = strictOptional(obj, name, owner)
  if value.isSome:
    some(decodeId(idType, value.get, owner & "." & name))
  else:
    none(Id[Kind])

proc stringField(obj: JsonNode; name, owner: string;
                 nullable = false): DiscordField[string] =
  if not obj.hasKey(name):
    return absent[string]()
  if obj[name].kind == JNull:
    if nullable:
      return nullValue[string]()
    raiseDecode(owner & "." & name & " must not be null")
  present(asString(obj[name], owner & "." & name))

proc boolField(obj: JsonNode; name, owner: string): DiscordField[bool] =
  if not obj.hasKey(name):
    return absent[bool]()
  if obj[name].kind == JNull:
    raiseDecode(owner & "." & name & " must not be null")
  present(asBool(obj[name], owner & "." & name))

proc intField(obj: JsonNode; name, owner: string): DiscordField[int64] =
  if not obj.hasKey(name):
    return absent[int64]()
  if obj[name].kind == JNull:
    raiseDecode(owner & "." & name & " must not be null")
  present(asInt(obj[name], owner & "." & name))

proc timestampField(obj: JsonNode; name, owner: string;
                    nullable = false): DiscordField[Timestamp] =
  if not obj.hasKey(name):
    return absent[Timestamp]()
  if obj[name].kind == JNull:
    if nullable:
      return nullValue[Timestamp]()
    raiseDecode(owner & "." & name & " must not be null")
  present(decodeTimestamp(obj[name], owner & "." & name))

proc idField[Kind](idType: typedesc[Id[Kind]]; obj: JsonNode;
                   name, owner: string): DiscordField[Id[Kind]] =
  if not obj.hasKey(name):
    return absent[Id[Kind]]()
  if obj[name].kind == JNull:
    raiseDecode(owner & "." & name & " must not be null")
  present(decodeId(idType, obj[name], owner & "." & name))

proc messageAuthorField(
    obj: JsonNode; name, owner: string;
    webhookId: DiscordField[WebhookId],
): DiscordField[MessageAuthor] =
  if not obj.hasKey(name):
    return absent[MessageAuthor]()
  if obj[name].kind == JNull:
    raiseDecode(owner & "." & name & " must not be null")
  let authorWebhookId = if webhookId.isPresent:
      some(webhookId.get)
    else:
      none(WebhookId)
  present(decodeMessageAuthor(obj[name], authorWebhookId))

proc decodeReady(node: JsonNode): ReadyEvent =
  let obj = ensureObject(node, "gateway.ready")
  result.version = asInt(requireField(obj, "v", "gateway.ready"),
    "gateway.ready.v")
  result.user = decodeUser(requireField(obj, "user", "gateway.ready"))
  for guildNode in asArray(requireField(obj, "guilds", "gateway.ready"),
      "gateway.ready.guilds"):
    let guildObj = ensureObject(guildNode, "gateway.ready.guild")
    let unavailable = asBool(
      requireField(guildObj, "unavailable", "gateway.ready.guild"),
      "gateway.ready.guild.unavailable")
    if not unavailable:
      raiseDecode("gateway.ready.guild.unavailable must be true")
    result.guilds.add ReadyUnavailableGuild(
      id: decodeId(GuildId,
        requireField(guildObj, "id", "gateway.ready.guild"),
        "gateway.ready.guild.id"),
      unavailable: true)
  result.sessionId = asString(
    requireField(obj, "session_id", "gateway.ready"),
    "gateway.ready.session_id")
  if result.sessionId.len == 0:
    raiseDecode("gateway.ready.session_id must not be empty")
  result.resumeGatewayUrl = asString(
    requireField(obj, "resume_gateway_url", "gateway.ready"),
    "gateway.ready.resume_gateway_url")
  if result.resumeGatewayUrl.len == 0:
    raiseDecode("gateway.ready.resume_gateway_url must not be empty")
  let shard = strictOptional(obj, "shard", "gateway.ready")
  if shard.isSome:
    let values = asArray(shard.get, "gateway.ready.shard")
    if values.len != 2:
      raiseDecode("gateway.ready.shard must contain id and total")
    let id = asInt(values[0], "gateway.ready.shard[0]")
    let total = asInt(values[1], "gateway.ready.shard[1]")
    if id < 0 or id > int64(high(uint16)) or total < 1 or
        total > int64(high(uint16)) or id >= total:
      raiseDecode("gateway.ready.shard is out of range")
    result.shard = some(ReadyShard(id: ShardId(uint16(id)),
      total: uint16(total)))
  let application = ensureObject(
    requireField(obj, "application", "gateway.ready"),
    "gateway.ready.application")
  result.application = ReadyApplication(
    id: decodeId(ApplicationId,
      requireField(application, "id", "gateway.ready.application"),
      "gateway.ready.application.id"),
    flags: asInt(
      requireField(application, "flags", "gateway.ready.application"),
      "gateway.ready.application.flags"))

proc decodeGuildCreate(node: JsonNode): GuildCreateEvent =
  let obj = ensureObject(node, "gateway.guild_create")
  let unavailable = strictOptional(
    obj, "unavailable", "gateway.guild_create")
  if unavailable.isSome and asBool(
      unavailable.get, "gateway.guild_create.unavailable"):
    return GuildCreateEvent(
      unavailable: true,
      guildId: decodeId(GuildId,
        requireField(obj, "id", "gateway.guild_create"),
        "gateway.guild_create.id"))
  result = GuildCreateEvent(
    unavailable: false,
    guild: decodeGuild(obj),
    joinedAt: decodeTimestamp(
      requireField(obj, "joined_at", "gateway.guild_create"),
      "gateway.guild_create.joined_at"),
    large: asBool(requireField(obj, "large", "gateway.guild_create"),
      "gateway.guild_create.large"),
    memberCount: asInt(
      requireField(obj, "member_count", "gateway.guild_create"),
      "gateway.guild_create.member_count"))
  for name in ["voice_states", "members", "channels", "threads",
      "presences", "stage_instances", "guild_scheduled_events",
      "soundboard_sounds"]:
    discard asArray(requireField(obj, name, "gateway.guild_create"),
      "gateway.guild_create." & name)

proc decodeGuildDelete(node: JsonNode): GuildDeleteEvent =
  let obj = ensureObject(node, "gateway.guild_delete")
  result.id = decodeId(GuildId,
    requireField(obj, "id", "gateway.guild_delete"),
    "gateway.guild_delete.id")
  let unavailable = strictOptional(obj, "unavailable", "gateway.guild_delete")
  if unavailable.isSome:
    result.unavailable = some(asBool(
      unavailable.get, "gateway.guild_delete.unavailable"))

proc decodeThreadDelete(node: JsonNode): ThreadDeleteEvent =
  let obj = ensureObject(node, "gateway.thread_delete")
  result.id = decodeId(ChannelId,
    requireField(obj, "id", "gateway.thread_delete"),
    "gateway.thread_delete.id")
  result.guildId = decodeId(GuildId,
    requireField(obj, "guild_id", "gateway.thread_delete"),
    "gateway.thread_delete.guild_id")
  result.parentId = decodeId(ChannelId,
    requireField(obj, "parent_id", "gateway.thread_delete"),
    "gateway.thread_delete.parent_id")
  result.kind = decodeIntEnum(ChannelType,
    requireField(obj, "type", "gateway.thread_delete"),
    "gateway.thread_delete.type")

proc decodeMemberUpdate(node: JsonNode): GuildMemberUpdateEvent =
  let obj = ensureObject(node, "gateway.guild_member_update")
  result.guildId = decodeId(GuildId,
    requireField(obj, "guild_id", "gateway.guild_member_update"),
    "gateway.guild_member_update.guild_id")
  for index, roleNode in asArray(
      requireField(obj, "roles", "gateway.guild_member_update"),
      "gateway.guild_member_update.roles"):
    result.roles.add decodeId(RoleId, roleNode,
      "gateway.guild_member_update.roles[" & $index & "]")
  result.user = decodeUser(
    requireField(obj, "user", "gateway.guild_member_update"))
  result.nick = stringField(obj, "nick", "gateway.guild_member_update",
    nullable = true)
  result.avatar = reqNullableString(
    obj, "avatar", "gateway.guild_member_update")
  result.banner = reqNullableString(
    obj, "banner", "gateway.guild_member_update")
  result.joinedAt = reqNullableTimestamp(
    obj, "joined_at", "gateway.guild_member_update")
  result.premiumSince = timestampField(
    obj, "premium_since", "gateway.guild_member_update", nullable = true)
  result.deaf = boolField(obj, "deaf", "gateway.guild_member_update")
  result.mute = boolField(obj, "mute", "gateway.guild_member_update")
  result.pending = boolField(obj, "pending", "gateway.guild_member_update")
  result.communicationDisabledUntil = timestampField(obj,
    "communication_disabled_until", "gateway.guild_member_update",
    nullable = true)

proc decodeMemberRemove(node: JsonNode): GuildMemberRemoveEvent =
  let obj = ensureObject(node, "gateway.guild_member_remove")
  result.guildId = decodeId(GuildId,
    requireField(obj, "guild_id", "gateway.guild_member_remove"),
    "gateway.guild_member_remove.guild_id")
  result.user = decodeUser(
    requireField(obj, "user", "gateway.guild_member_remove"))

proc decodeRoleEvent(node: JsonNode): GuildRoleEvent =
  let obj = ensureObject(node, "gateway.guild_role")
  result.guildId = decodeId(GuildId,
    requireField(obj, "guild_id", "gateway.guild_role"),
    "gateway.guild_role.guild_id")
  result.role = decodeRole(requireField(obj, "role", "gateway.guild_role"))

proc decodeRoleDelete(node: JsonNode): GuildRoleDeleteEvent =
  let obj = ensureObject(node, "gateway.guild_role_delete")
  result.guildId = decodeId(GuildId,
    requireField(obj, "guild_id", "gateway.guild_role_delete"),
    "gateway.guild_role_delete.guild_id")
  result.roleId = decodeId(RoleId,
    requireField(obj, "role_id", "gateway.guild_role_delete"),
    "gateway.guild_role_delete.role_id")

proc decodeMessageUpdate(node: JsonNode): MessageUpdateEvent =
  let obj = ensureObject(node, "gateway.message_update")
  result.id = decodeId(MessageId,
    requireField(obj, "id", "gateway.message_update"),
    "gateway.message_update.id")
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "gateway.message_update"),
    "gateway.message_update.channel_id")
  result.guildId = optionalId(
    GuildId, obj, "guild_id", "gateway.message_update")
  result.webhookId = idField(
    WebhookId, obj, "webhook_id", "gateway.message_update")
  result.author = messageAuthorField(
    obj, "author", "gateway.message_update", result.webhookId)
  result.content = stringField(obj, "content", "gateway.message_update")
  result.editedTimestamp = timestampField(
    obj, "edited_timestamp", "gateway.message_update", nullable = true)
  result.pinned = boolField(obj, "pinned", "gateway.message_update")
  result.flags = intField(obj, "flags", "gateway.message_update")
  result.snapshot = initSnapshot(obj, ["id", "channel_id", "guild_id",
    "webhook_id", "author", "content", "edited_timestamp", "pinned", "flags"])

proc decodeMessageDelete(node: JsonNode): MessageDeleteEvent =
  let obj = ensureObject(node, "gateway.message_delete")
  result.id = decodeId(MessageId,
    requireField(obj, "id", "gateway.message_delete"),
    "gateway.message_delete.id")
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "gateway.message_delete"),
    "gateway.message_delete.channel_id")
  result.guildId = optionalId(
    GuildId, obj, "guild_id", "gateway.message_delete")

proc decodeMessageDeleteBulk(node: JsonNode): MessageDeleteBulkEvent =
  let obj = ensureObject(node, "gateway.message_delete_bulk")
  let values = asArray(
    requireField(obj, "ids", "gateway.message_delete_bulk"),
    "gateway.message_delete_bulk.ids")
  if values.len == 0:
    raiseDecode("gateway.message_delete_bulk.ids must not be empty")
  for index, idNode in values:
    let id = decodeId(MessageId, idNode,
      "gateway.message_delete_bulk.ids[" & $index & "]")
    if id in result.ids:
      raiseDecode("gateway.message_delete_bulk.ids must be unique")
    result.ids.add id
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "gateway.message_delete_bulk"),
    "gateway.message_delete_bulk.channel_id")
  result.guildId = optionalId(
    GuildId, obj, "guild_id", "gateway.message_delete_bulk")

proc decodeReaction(node: JsonNode): MessageReactionEvent =
  let obj = ensureObject(node, "gateway.message_reaction")
  result.userId = decodeId(UserId,
    requireField(obj, "user_id", "gateway.message_reaction"),
    "gateway.message_reaction.user_id")
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "gateway.message_reaction"),
    "gateway.message_reaction.channel_id")
  result.messageId = decodeId(MessageId,
    requireField(obj, "message_id", "gateway.message_reaction"),
    "gateway.message_reaction.message_id")
  result.guildId = optionalId(
    GuildId, obj, "guild_id", "gateway.message_reaction")
  result.emoji = decodePartialEmoji(
    requireField(obj, "emoji", "gateway.message_reaction"),
    "gateway.message_reaction.emoji")
  let member = strictOptional(obj, "member", "gateway.message_reaction")
  if member.isSome:
    result.member = some(decodeGuildMember(member.get))
  result.messageAuthorId = optionalId(
    UserId, obj, "message_author_id", "gateway.message_reaction")
  result.burst = asBool(
    requireField(obj, "burst", "gateway.message_reaction"),
    "gateway.message_reaction.burst")
  let colors = strictOptional(
    obj, "burst_colors", "gateway.message_reaction")
  if colors.isSome:
    for index, colorNode in asArray(
        colors.get, "gateway.message_reaction.burst_colors"):
      result.burstColors.add asString(colorNode,
        "gateway.message_reaction.burst_colors[" & $index & "]")
  result.reactionType = asInt(
    requireField(obj, "type", "gateway.message_reaction"),
    "gateway.message_reaction.type")
  result.snapshot = initSnapshot(obj, ["user_id", "channel_id", "message_id",
    "guild_id", "emoji", "member", "message_author_id", "burst",
    "burst_colors", "type"])

proc decodeReactionRemoveAll(node: JsonNode): MessageReactionRemoveAllEvent =
  let obj = ensureObject(node, "gateway.message_reaction_remove_all")
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "gateway.message_reaction_remove_all"),
    "gateway.message_reaction_remove_all.channel_id")
  result.messageId = decodeId(MessageId,
    requireField(obj, "message_id", "gateway.message_reaction_remove_all"),
    "gateway.message_reaction_remove_all.message_id")
  result.guildId = optionalId(GuildId, obj, "guild_id",
    "gateway.message_reaction_remove_all")

proc decodeReactionRemoveEmoji(
    node: JsonNode): MessageReactionRemoveEmojiEvent =
  let obj = ensureObject(node, "gateway.message_reaction_remove_emoji")
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "gateway.message_reaction_remove_emoji"),
    "gateway.message_reaction_remove_emoji.channel_id")
  result.messageId = decodeId(MessageId,
    requireField(obj, "message_id", "gateway.message_reaction_remove_emoji"),
    "gateway.message_reaction_remove_emoji.message_id")
  result.guildId = optionalId(GuildId, obj, "guild_id",
    "gateway.message_reaction_remove_emoji")
  result.emoji = decodePartialEmoji(
    requireField(obj, "emoji", "gateway.message_reaction_remove_emoji"),
    "gateway.message_reaction_remove_emoji.emoji")

proc decodePollVote(node: JsonNode): MessagePollVoteEvent =
  let obj = ensureObject(node, "gateway.message_poll_vote")
  result.userId = decodeId(UserId,
    requireField(obj, "user_id", "gateway.message_poll_vote"),
    "gateway.message_poll_vote.user_id")
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "gateway.message_poll_vote"),
    "gateway.message_poll_vote.channel_id")
  result.messageId = decodeId(MessageId,
    requireField(obj, "message_id", "gateway.message_poll_vote"),
    "gateway.message_poll_vote.message_id")
  result.guildId = optionalId(
    GuildId, obj, "guild_id", "gateway.message_poll_vote")
  result.answerId = asInt(
    requireField(obj, "answer_id", "gateway.message_poll_vote"),
    "gateway.message_poll_vote.answer_id")
  if result.answerId < 1:
    raiseDecode("gateway.message_poll_vote.answer_id must be positive")

proc decodeWebhooksUpdate(node: JsonNode): WebhooksUpdateEvent =
  let obj = ensureObject(node, "gateway.webhooks_update")
  result.guildId = decodeId(GuildId,
    requireField(obj, "guild_id", "gateway.webhooks_update"),
    "gateway.webhooks_update.guild_id")
  result.channelId = decodeId(ChannelId,
    requireField(obj, "channel_id", "gateway.webhooks_update"),
    "gateway.webhooks_update.channel_id")

proc eventData(event: DispatchEvent): JsonNode =
  try:
    parseJson(event.payload)
  except CatchableError:
    raiseDecode("Gateway dispatch payload is not valid JSON")

proc decodeGatewayEvent*(event: DispatchEvent): GatewayEvent =
  ## Decodes one queued dispatch without exposing payload bytes in failures.
  ##
  ## Unknown names are successful and retain an owned copy of `d`. Known names
  ## reject malformed documented fields with `DecodeError`.
  # INTERACTION_CREATE owns callback credentials and is admitted directly by
  # GatewayShardRunner into the interaction runtime. Treating it as a typed or
  # unknown generic event would recreate a handler-visible token escape hatch.
  if event.name == "INTERACTION_CREATE":
    raiseDecode("INTERACTION_CREATE is reserved for dedicated interaction ingress")
  let data = event.eventData()
  result.shardId = event.shardId
  result.sequence = event.sequence
  result.partitionKey = event.partitionKey
  result.receivedAtMs = event.receivedAtMs
  case event.name
  of "READY":
    result = GatewayEvent(kind: gekReady, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs, ready: decodeReady(data))
  of "RESUMED":
    discard ensureObject(data, "gateway.resumed")
    result = GatewayEvent(kind: gekResumed, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs)
  of "GUILD_CREATE":
    result = GatewayEvent(kind: gekGuildCreate, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      guildCreate: decodeGuildCreate(data))
  of "GUILD_UPDATE":
    result = GatewayEvent(kind: gekGuildUpdate, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs, guildUpdate: decodeGuild(data))
  of "GUILD_DELETE":
    result = GatewayEvent(kind: gekGuildDelete, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      guildDelete: decodeGuildDelete(data))
  of "CHANNEL_CREATE", "CHANNEL_UPDATE", "CHANNEL_DELETE", "THREAD_CREATE",
      "THREAD_UPDATE":
    let decoded = decodeChannel(data)
    template channelEvent(eventKind: untyped): untyped =
      GatewayEvent(kind: eventKind, shardId: event.shardId,
        sequence: event.sequence, partitionKey: event.partitionKey,
        receivedAtMs: event.receivedAtMs, channel: decoded)
    case event.name
    of "CHANNEL_CREATE": result = channelEvent(gekChannelCreate)
    of "CHANNEL_UPDATE": result = channelEvent(gekChannelUpdate)
    of "CHANNEL_DELETE": result = channelEvent(gekChannelDelete)
    of "THREAD_CREATE": result = channelEvent(gekThreadCreate)
    else: result = channelEvent(gekThreadUpdate)
  of "THREAD_DELETE":
    result = GatewayEvent(kind: gekThreadDelete, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      threadDelete: decodeThreadDelete(data))
  of "GUILD_MEMBER_ADD":
    let obj = ensureObject(data, "gateway.guild_member_add")
    result = GatewayEvent(kind: gekGuildMemberAdd, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      memberAdded: GuildMemberAddEvent(
        guildId: decodeId(GuildId,
          requireField(obj, "guild_id", "gateway.guild_member_add"),
          "gateway.guild_member_add.guild_id"),
        member: decodeGuildMember(obj)))
  of "GUILD_MEMBER_UPDATE":
    result = GatewayEvent(kind: gekGuildMemberUpdate, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      memberUpdated: decodeMemberUpdate(data))
  of "GUILD_MEMBER_REMOVE":
    result = GatewayEvent(kind: gekGuildMemberRemove, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      memberRemoved: decodeMemberRemove(data))
  of "GUILD_ROLE_CREATE", "GUILD_ROLE_UPDATE":
    let decoded = decodeRoleEvent(data)
    if event.name == "GUILD_ROLE_CREATE":
      result = GatewayEvent(kind: gekGuildRoleCreate,
        shardId: event.shardId, sequence: event.sequence,
        partitionKey: event.partitionKey, receivedAtMs: event.receivedAtMs,
        guildRole: decoded)
    else:
      result = GatewayEvent(kind: gekGuildRoleUpdate,
        shardId: event.shardId, sequence: event.sequence,
        partitionKey: event.partitionKey, receivedAtMs: event.receivedAtMs,
        guildRole: decoded)
  of "GUILD_ROLE_DELETE":
    result = GatewayEvent(kind: gekGuildRoleDelete, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      guildRoleDelete: decodeRoleDelete(data))
  of "MESSAGE_CREATE":
    result = GatewayEvent(kind: gekMessageCreate, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs, messageCreated: decodeMessage(data))
  of "MESSAGE_UPDATE":
    result = GatewayEvent(kind: gekMessageUpdate, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      messageUpdated: decodeMessageUpdate(data))
  of "MESSAGE_DELETE":
    result = GatewayEvent(kind: gekMessageDelete, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      messageDeleted: decodeMessageDelete(data))
  of "MESSAGE_DELETE_BULK":
    result = GatewayEvent(kind: gekMessageDeleteBulk, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      messagesDeleted: decodeMessageDeleteBulk(data))
  of "MESSAGE_REACTION_ADD", "MESSAGE_REACTION_REMOVE":
    let decoded = decodeReaction(data)
    if event.name == "MESSAGE_REACTION_ADD":
      result = GatewayEvent(kind: gekMessageReactionAdd,
        shardId: event.shardId, sequence: event.sequence,
        partitionKey: event.partitionKey, receivedAtMs: event.receivedAtMs,
        reaction: decoded)
    else:
      result = GatewayEvent(kind: gekMessageReactionRemove,
        shardId: event.shardId, sequence: event.sequence,
        partitionKey: event.partitionKey, receivedAtMs: event.receivedAtMs,
        reaction: decoded)
  of "MESSAGE_REACTION_REMOVE_ALL":
    result = GatewayEvent(kind: gekMessageReactionRemoveAll,
      shardId: event.shardId, sequence: event.sequence,
      partitionKey: event.partitionKey, receivedAtMs: event.receivedAtMs,
      reactionsRemoved: decodeReactionRemoveAll(data))
  of "MESSAGE_REACTION_REMOVE_EMOJI":
    result = GatewayEvent(kind: gekMessageReactionRemoveEmoji,
      shardId: event.shardId, sequence: event.sequence,
      partitionKey: event.partitionKey, receivedAtMs: event.receivedAtMs,
      reactionEmojiRemoved: decodeReactionRemoveEmoji(data))
  of "MESSAGE_POLL_VOTE_ADD", "MESSAGE_POLL_VOTE_REMOVE":
    let decoded = decodePollVote(data)
    if event.name == "MESSAGE_POLL_VOTE_ADD":
      result = GatewayEvent(kind: gekMessagePollVoteAdd,
        shardId: event.shardId, sequence: event.sequence,
        partitionKey: event.partitionKey, receivedAtMs: event.receivedAtMs,
        pollVote: decoded)
    else:
      result = GatewayEvent(kind: gekMessagePollVoteRemove,
        shardId: event.shardId, sequence: event.sequence,
        partitionKey: event.partitionKey, receivedAtMs: event.receivedAtMs,
        pollVote: decoded)
  of "WEBHOOKS_UPDATE":
    result = GatewayEvent(kind: gekWebhooksUpdate, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      webhooksUpdated: decodeWebhooksUpdate(data))
  of "ENTITLEMENT_CREATE", "ENTITLEMENT_UPDATE", "ENTITLEMENT_DELETE":
    let decoded = decodeEntitlement(data)
    template entitlementEvent(eventKind: untyped): untyped =
      GatewayEvent(kind: eventKind, shardId: event.shardId,
        sequence: event.sequence, partitionKey: event.partitionKey,
        receivedAtMs: event.receivedAtMs, entitlement: decoded)
    case event.name
    of "ENTITLEMENT_CREATE": result = entitlementEvent(gekEntitlementCreate)
    of "ENTITLEMENT_UPDATE": result = entitlementEvent(gekEntitlementUpdate)
    else: result = entitlementEvent(gekEntitlementDelete)
  of "SUBSCRIPTION_CREATE", "SUBSCRIPTION_UPDATE", "SUBSCRIPTION_DELETE":
    let decoded = decodeSubscription(data)
    template subscriptionEvent(eventKind: untyped): untyped =
      GatewayEvent(kind: eventKind, shardId: event.shardId,
        sequence: event.sequence, partitionKey: event.partitionKey,
        receivedAtMs: event.receivedAtMs, subscription: decoded)
    case event.name
    of "SUBSCRIPTION_CREATE":
      result = subscriptionEvent(gekSubscriptionCreate)
    of "SUBSCRIPTION_UPDATE":
      result = subscriptionEvent(gekSubscriptionUpdate)
    else:
      result = subscriptionEvent(gekSubscriptionDelete)
  else:
    result = GatewayEvent(kind: gekUnknown, shardId: event.shardId,
      sequence: event.sequence, partitionKey: event.partitionKey,
      receivedAtMs: event.receivedAtMs,
      unknown: UnknownGatewayEvent(name: event.name, dataValue: data.copy()))

func rawData*(event: UnknownGatewayEvent): JsonNode =
  ## Returns an owned copy of the future event payload.
  ##
  ## This is an explicit raw escape and can contain user content or credentials;
  ## do not include it in logs or diagnostics.
  event.dataValue.copy()

proc rawJson*(event: MessageUpdateEvent): JsonNode =
  ## Returns an owned copy of the complete partial-update payload.
  rawJson(event.snapshot)

proc unknownFields*(event: MessageUpdateEvent): seq[UnknownField] =
  ## Returns fields not projected by `MessageUpdateEvent`.
  unknownFields(event.snapshot)

proc rawJson*(event: MessageReactionEvent): JsonNode =
  ## Returns an owned copy of the complete reaction payload.
  rawJson(event.snapshot)

proc unknownFields*(event: MessageReactionEvent): seq[UnknownField] =
  ## Returns reaction fields not projected by this version.
  unknownFields(event.snapshot)

func unknownSummary(event: UnknownGatewayEvent): string =
  ## Deliberately excludes the forward-compatible raw payload.
  "UnknownGatewayEvent(name: " & event.name & ")"

func `$`*(event: UnknownGatewayEvent): string =
  ## Renders only the event name; `rawData` is the explicit sensitive escape.
  event.unknownSummary()

func repr*(event: UnknownGatewayEvent): string =
  ## Uses the same raw-data-free representation as `$`.
  event.unknownSummary()

proc `%`*(event: UnknownGatewayEvent): JsonNode =
  ## Serializes only safe routing metadata, never the retained raw payload.
  %*{"name": event.name}

proc toJsonHook*(event: UnknownGatewayEvent): JsonNode =
  ## Redacts unknown event data serialized through `std/jsonutils`.
  %event

func `$`*(event: GatewayEvent): string =
  ## Renders metadata only; event bodies and interaction credentials are omitted.
  "GatewayEvent(kind: " & $event.kind & ", shard: " &
    $uint16(event.shardId) & ", sequence: " &
    $event.sequence.toInt64 & ")"

func repr*(event: GatewayEvent): string =
  ## Uses the same body-free representation as `$`.
  $event

proc `%`*(event: GatewayEvent): JsonNode =
  ## Serializes only stable ingress metadata, never an event body.
  %*{
    "kind": $event.kind,
    "shardId": int(event.shardId.toUint16),
    "sequence": event.sequence.toInt64,
    "partitionKey": $event.partitionKey,
    "receivedAtMs": event.receivedAtMs,
  }

proc toJsonHook*(event: GatewayEvent): JsonNode =
  ## Redacts event bodies serialized through `std/jsonutils`.
  %event

proc typedGatewayHandler*(handler: TypedGatewayEventHandler):
    GatewayDispatchHandler =
  ## Adapts a typed handler to the bounded raw dispatch runtime.
  ##
  ## Decoding runs in the selected handler lane, never in the unique shard
  ## reader. A decode or handler failure is therefore isolated by the existing
  ## `GatewayDispatchRuntime` error observer.
  if handler.isNil:
    raise newException(ValueError, "typed Gateway handler must not be nil")
  result = proc(event: DispatchEvent): Future[void] {.
      closure, gcsafe, raises: [].} =
    proc run(): Future[void] {.async.} =
      await handler(decodeGatewayEvent(event))
    {.cast(gcsafe).}:
      return run()
