## Selective cache for Discord Gateway entities.
##
## `EntityCache` owns independent policy-controlled stores for guilds, channels
## and threads, members, messages, and presences. It keeps complete semantic JSON
## snapshots, including unknown fields, and returns a newly parsed value from
## every lookup so callers never receive a mutable alias into cache state.
##
## Each supported dispatch is validated before mutation. Available
## `GUILD_CREATE` and `THREAD_LIST_SYNC` payloads reconcile their authoritative
## channel or thread scope; member and presence lists remain partial. Deletes use
## internal ownership metadata so cascades do not depend on another store being
## enabled. Malformed events change nothing and expose no payload text through the
## observer.
##
## The cache performs no I/O and owns no asynchronous resources. One Chronos
## event-loop owner must call it. Use `cachingHandler` with an ordered or
## guild-partitioned dispatch policy when handlers require causal cache updates.

import std/[hashes, json, options, sets]

import chronos

import ../cache
import ../core/ids
import ./dispatch_runtime

type
  MemberKey* = object ## Cache key for one guild member.
    guildId*: GuildId ## Guild the member belongs to.
    userId*: UserId ## Member's user snowflake.

  MessageKey* = object ## Cache key for one channel message.
    channelId*: ChannelId ## Channel the message was sent in.
    messageId*: MessageId ## Message snowflake.

  PresenceKey* = object ## Cache key for one guild presence.
    guildId*: GuildId ## Guild the presence was observed in.
    userId*: UserId ## User whose presence this is.

  CachedEntity = object ## Immutable stored value: serialized payload plus scope.
    payloadJson: string ## Serialized JSON of the payload. Preserves the JSON
                        ## value and every field, not the original byte encoding.
    guildId: Option[GuildId] ## Owning guild for cascade; never injected into the
                             ## payload the caller reads back.

  CacheApplyOutcome* = enum ## Result of applying one dispatch event.
    caIgnored, ## The event name is not cached; nothing changed.
    caApplied, ## The event was validated and applied (store, merge, or delete).
    caMalformed ## The payload failed validation; nothing was cached.

  CacheApplyResult* = object ## Redaction-safe outcome of one `apply` call.
    outcome*: CacheApplyOutcome ## Classification of what happened.
    eventName*: string ## Dispatch event name; low-cardinality, never a secret.
    detail*: string ## Fixed developer-authored note; never payload or exception
                    ## text.

  CacheApplyObserver* = proc(res: CacheApplyResult) {.gcsafe, raises: [].}
    ## Optional sink for every `apply` outcome. Receives only redaction-safe
    ## metadata and must not raise.

  CacheLookup* = object ## A cache hit with its provenance and a fresh payload.
    revision*: uint64 ## Store-local revision at which the value was stored.
    observedAtMs*: int64 ## Monotonic instant the value was observed.
    payload*: JsonNode ## Freshly decoded payload; safe to mutate freely.

  EntityCacheStats* = object ## Per-domain cumulative cache counters.
    guilds*: CacheStats ## Guild store counters.
    channels*: CacheStats ## Channel and thread store counters.
    members*: CacheStats ## Member store counters.
    messages*: CacheStats ## Message store counters.
    presences*: CacheStats ## Presence store counters.

  EntityCache* = ref object ## Selective Gateway snapshot cache for one loop.
    clock: MonotonicClock
    guilds: CacheStore[GuildId, CachedEntity]
    channels: CacheStore[ChannelId, CachedEntity]
    members: CacheStore[MemberKey, CachedEntity]
    messages: CacheStore[MessageKey, CachedEntity]
    presences: CacheStore[PresenceKey, CachedEntity]

func hash*(key: MemberKey): Hash =
  ## Combines both snowflakes so member keys are stable table keys.
  var h = hash(key.guildId)
  h = h !& hash(key.userId)
  !$h

func `==`*(left, right: MemberKey): bool =
  left.guildId == right.guildId and left.userId == right.userId

func hash*(key: MessageKey): Hash =
  var h = hash(key.channelId)
  h = h !& hash(key.messageId)
  !$h

func `==`*(left, right: MessageKey): bool =
  left.channelId == right.channelId and left.messageId == right.messageId

func hash*(key: PresenceKey): Hash =
  var h = hash(key.guildId)
  h = h !& hash(key.userId)
  !$h

func `==`*(left, right: PresenceKey): bool =
  left.guildId == right.guildId and left.userId == right.userId

func memberKey*(guildId: GuildId, userId: UserId): MemberKey =
  ## Builds a member cache key.
  MemberKey(guildId: guildId, userId: userId)

func messageKey*(channelId: ChannelId, messageId: MessageId): MessageKey =
  ## Builds a message cache key.
  MessageKey(channelId: channelId, messageId: messageId)

func presenceKey*(guildId: GuildId, userId: UserId): PresenceKey =
  ## Builds a presence cache key.
  PresenceKey(guildId: guildId, userId: userId)

proc newEntityCache*(policies: CachePolicies, clock: MonotonicClock):
    EntityCache =
  ## Creates an empty cache with one store per domain governed by `policies`.
  ##
  ## `clock` supplies the monotonic milliseconds used for TTL expiry on lookups;
  ## it must be non-decreasing. Disabled domains retain nothing.
  if clock.isNil:
    raise newException(ValueError, "entity cache clock must not be nil")
  EntityCache(
    clock: clock,
    guilds: initCacheStore[GuildId, CachedEntity](policies.guilds),
    channels: initCacheStore[ChannelId, CachedEntity](policies.channels),
    members: initCacheStore[MemberKey, CachedEntity](policies.members),
    messages: initCacheStore[MessageKey, CachedEntity](policies.messages),
    presences: initCacheStore[PresenceKey, CachedEntity](policies.presences),
  )

# --- payload helpers ---------------------------------------------------------

proc snowflake[K](kind: typedesc[Id[K]], node: JsonNode): Option[Id[K]] =
  ## Parses a decimal-string snowflake field, rejecting anything else.
  if node.isNil or node.kind != JString:
    return none(Id[K])
  try:
    some(parseId(kind, node.getStr()))
  except ValueError:
    none(Id[K])

type OptionalFieldState = enum ## Three states of an optional typed field.
  ofsAbsent, ## The field is not present.
  ofsPresent, ## The field is present and well-formed.
  ofsInvalid ## The field is present but the wrong type or unparseable.

proc optionalGuildScope(payload: JsonNode):
    tuple[state: OptionalFieldState, id: GuildId] =
  ## Three-state parse of an optional `guild_id` scope field.
  ##
  ## Absent, present-valid, and present-invalid are kept distinct: a present but
  ## malformed `guild_id` is `ofsInvalid` (an error), never silently `absent`.
  let node = payload{"guild_id"}
  if node.isNil:
    return (ofsAbsent, GuildId(0))
  if node.kind != JString:
    return (ofsInvalid, GuildId(0))
  try:
    (ofsPresent, parseId(GuildId, node.getStr()))
  except ValueError:
    (ofsInvalid, GuildId(0))

proc optionalBoolField(payload: JsonNode; key: string):
    tuple[state: OptionalFieldState, value: bool] =
  ## Three-state parse of an optional boolean field (for example `unavailable`).
  let node = payload{key}
  if node.isNil:
    return (ofsAbsent, false)
  if node.kind != JBool:
    return (ofsInvalid, false)
  (ofsPresent, node.getBool())

func isThreadType(channelType: int): bool =
  ## Reports whether a Discord channel type denotes a thread (10, 11, 12).
  channelType == 10 or channelType == 11 or channelType == 12

func applied(eventName: string): CacheApplyResult =
  CacheApplyResult(outcome: caApplied, eventName: eventName)

func ignored(eventName: string): CacheApplyResult =
  CacheApplyResult(outcome: caIgnored, eventName: eventName)

func malformed(eventName, detail: string): CacheApplyResult =
  CacheApplyResult(outcome: caMalformed, eventName: eventName, detail: detail)

proc upsert[K](store: var CacheStore[K, CachedEntity]; key: K; payload: JsonNode;
               observedAtMs: int64; merge: bool; scope: Option[GuildId]) =
  ## Stores `payload`, optionally merging its top-level fields onto an existing
  ## snapshot. `scope` is the owning guild recorded for cascade; on a merge with
  ## no new scope, the prior scope is preserved. A disabled store retains nothing.
  var finalScope = scope
  if merge:
    let existing = store.peek(key, observedAtMs)
    if existing.isSome:
      let merged = parseJson(existing.get.value.payloadJson)
      for name, value in payload:
        merged[name] = value
      if finalScope.isNone:
        finalScope = existing.get.value.guildId
      discard store.put(key,
        CachedEntity(payloadJson: $merged, guildId: finalScope), observedAtMs)
      return
  discard store.put(key,
    CachedEntity(payloadJson: $payload, guildId: finalScope), observedAtMs)

# --- per-domain application --------------------------------------------------

proc childChannels(arr: JsonNode): Option[seq[(ChannelId, JsonNode)]] =
  var items: seq[(ChannelId, JsonNode)]
  for element in arr:
    if element.kind != JObject:
      return none(seq[(ChannelId, JsonNode)])
    let id = snowflake(ChannelId, element{"id"})
    if id.isNone:
      return none(seq[(ChannelId, JsonNode)])
    items.add (id.get, element)
  some(items)

proc childUsers(arr: JsonNode): Option[seq[(UserId, JsonNode)]] =
  var items: seq[(UserId, JsonNode)]
  for element in arr:
    if element.kind != JObject:
      return none(seq[(UserId, JsonNode)])
    let id = snowflake(UserId, element{"user", "id"})
    if id.isNone:
      return none(seq[(UserId, JsonNode)])
    items.add (id.get, element)
  some(items)

type
  ChannelArray = object ## Validated optional array of channel-shaped children.
    present: bool ## Whether the field was present at all.
    valid: bool ## Whether a present field parsed cleanly.
    items: seq[(ChannelId, JsonNode)] ## Decoded children, empty unless valid.

  UserArray = object ## Validated optional array of user-keyed children.
    present: bool ## Whether the field was present at all.
    valid: bool ## Whether a present field parsed cleanly.
    items: seq[(UserId, JsonNode)] ## Decoded children, empty unless valid.

proc channelArray(payload: JsonNode; field: string): ChannelArray =
  ## Three-state validation of an optional channel-shaped nested array.
  let arr = payload{field}
  if arr.isNil:
    return ChannelArray(present: false, valid: true)
  if arr.kind != JArray:
    return ChannelArray(present: true, valid: false)
  let decoded = childChannels(arr)
  if decoded.isNone:
    return ChannelArray(present: true, valid: false)
  ChannelArray(present: true, valid: true, items: decoded.get)

proc userArray(payload: JsonNode; field: string): UserArray =
  ## Three-state validation of an optional user-keyed nested array.
  let arr = payload{field}
  if arr.isNil:
    return UserArray(present: false, valid: true)
  if arr.kind != JArray:
    return UserArray(present: true, valid: false)
  let decoded = childUsers(arr)
  if decoded.isNone:
    return UserArray(present: true, valid: false)
  UserArray(present: true, valid: true, items: decoded.get)

proc reconcileGuildChannels(cache: EntityCache; guildId: GuildId;
                            keep: HashSet[ChannelId]; channelsPresent,
                            threadsPresent: bool; observedAtMs: int64) =
  # An available GUILD_CREATE is authoritative for the channel and active-thread
  # lists it carries. Purge expired channels first so no expired remnant is
  # skipped by the sweep yet left to inflate a count, then remove cached regular
  # channels absent from a present `channels` list and cached threads absent from
  # a present `threads` list. The other kind, and members/presences, are kept.
  discard cache.channels.purgeExpired(observedAtMs)
  var stale: seq[ChannelId]
  for channelId, snapshot in cache.channels.pairs(observedAtMs):
    if snapshot.value.guildId != some(guildId) or channelId in keep:
      continue
    var isThread = false
    try:
      isThread = isThreadType(
        parseJson(snapshot.value.payloadJson){"type"}.getInt(-1))
    except CatchableError:
      continue
    if (isThread and threadsPresent) or ((not isThread) and channelsPresent):
      stale.add channelId
  for channelId in stale:
    cache.channels.del(channelId)

proc applyGuildCreate(cache: EntityCache; eventName: string; payload: JsonNode;
                      observedAtMs: int64): CacheApplyResult =
  let guildId = snowflake(GuildId, payload{"id"})
  if guildId.isNone:
    return malformed(eventName, "guild payload is missing a string id")

  let unavailable = payload.optionalBoolField("unavailable")
  if unavailable.state == ofsInvalid:
    return malformed(eventName, "guild unavailable is present but not a boolean")
  if unavailable.state == ofsPresent and unavailable.value:
    # An unavailable stub merges into existing data so a later recovery does not
    # resume from an erased guild; it carries no children to index or reconcile.
    cache.guilds.upsert(
      guildId.get, payload, observedAtMs, merge = true, scope = none(GuildId))
    return applied(eventName)

  # Available create: validate every nested array before mutating anything, so a
  # malformed child rejects the whole event instead of half-populating stores.
  let channels = payload.channelArray("channels")
  if not channels.valid:
    return malformed(eventName, "guild channels is malformed")
  let threads = payload.channelArray("threads")
  if not threads.valid:
    return malformed(eventName, "guild threads is malformed")
  let members = payload.userArray("members")
  if not members.valid:
    return malformed(eventName, "guild members is malformed")
  let presences = payload.userArray("presences")
  if not presences.valid:
    return malformed(eventName, "guild presences is malformed")

  # An available create is the authoritative full guild, so replace it.
  cache.guilds.upsert(
    guildId.get, payload, observedAtMs, merge = false, scope = none(GuildId))

  var keep: HashSet[ChannelId]
  for (channelId, _) in channels.items: keep.incl channelId
  for (channelId, _) in threads.items: keep.incl channelId
  if channels.present or threads.present:
    cache.reconcileGuildChannels(guildId.get, keep, channels.present,
      threads.present, observedAtMs)

  for children in [channels.items, threads.items]:
    for (channelId, node) in children:
      cache.channels.upsert(
        channelId, node, observedAtMs, merge = false, scope = some(guildId.get))
  for (userId, node) in members.items:
    cache.members.upsert(memberKey(guildId.get, userId), node, observedAtMs,
      merge = false, scope = some(guildId.get))
  for (userId, node) in presences.items:
    cache.presences.upsert(presenceKey(guildId.get, userId), node, observedAtMs,
      merge = false, scope = none(GuildId))
  applied(eventName)

proc applyGuildUpdate(cache: EntityCache; eventName: string; payload: JsonNode;
                      observedAtMs: int64): CacheApplyResult =
  let guildId = snowflake(GuildId, payload{"id"})
  if guildId.isNone:
    return malformed(eventName, "guild payload is missing a string id")
  cache.guilds.upsert(
    guildId.get, payload, observedAtMs, merge = true, scope = none(GuildId))
  applied(eventName)

proc applyChannel(cache: EntityCache; eventName: string; payload: JsonNode;
                  observedAtMs: int64; merge: bool): CacheApplyResult =
  let channelId = snowflake(ChannelId, payload{"id"})
  if channelId.isNone:
    return malformed(eventName, "channel payload is missing a string id")
  # A top-level channel names its own guild; a thread that came from GUILD_CREATE
  # keeps the scope recorded when it was indexed (merge preserves it). A present
  # but malformed guild_id is an error, not a silently DM-scoped channel.
  let scope = payload.optionalGuildScope()
  if scope.state == ofsInvalid:
    return malformed(eventName, "channel guild_id is present but not a snowflake")
  cache.channels.upsert(channelId.get, payload, observedAtMs, merge,
    scope = (if scope.state == ofsPresent: some(scope.id) else: none(GuildId)))
  applied(eventName)

proc applyMember(cache: EntityCache; eventName: string; payload: JsonNode;
                 observedAtMs: int64; merge: bool): CacheApplyResult =
  let guildId = snowflake(GuildId, payload{"guild_id"})
  let userId = snowflake(UserId, payload{"user", "id"})
  if guildId.isNone:
    return malformed(eventName, "member payload is missing a guild id")
  if userId.isNone:
    return malformed(eventName, "member payload is missing a user id")
  cache.members.upsert(memberKey(guildId.get, userId.get), payload,
    observedAtMs, merge, scope = some(guildId.get))
  applied(eventName)

proc applyMessage(cache: EntityCache; eventName: string; payload: JsonNode;
                  observedAtMs: int64; merge: bool): CacheApplyResult =
  let channelId = snowflake(ChannelId, payload{"channel_id"})
  let messageId = snowflake(MessageId, payload{"id"})
  if channelId.isNone:
    return malformed(eventName, "message payload is missing a channel id")
  if messageId.isNone:
    return malformed(eventName, "message payload is missing a message id")
  # A guild message carries guild_id; recording it lets a guild delete cascade
  # messages even when channel caching is disabled or the channel was evicted. A
  # present but malformed guild_id is an error, not a silently DM-scoped message.
  let scope = payload.optionalGuildScope()
  if scope.state == ofsInvalid:
    return malformed(eventName, "message guild_id is present but not a snowflake")
  cache.messages.upsert(messageKey(channelId.get, messageId.get), payload,
    observedAtMs, merge,
    scope = (if scope.state == ofsPresent: some(scope.id) else: none(GuildId)))
  applied(eventName)

proc applyPresence(cache: EntityCache; eventName: string; payload: JsonNode;
                   observedAtMs: int64): CacheApplyResult =
  let guildId = snowflake(GuildId, payload{"guild_id"})
  let userId = snowflake(UserId, payload{"user", "id"})
  if guildId.isNone:
    return malformed(eventName, "presence payload is missing a guild id")
  if userId.isNone:
    return malformed(eventName, "presence payload is missing a user id")
  # A PRESENCE_UPDATE has no create/delete counterpart and can be partial, so it
  # is always an upsert-merge onto the last observed presence.
  cache.presences.upsert(presenceKey(guildId.get, userId.get), payload,
    observedAtMs, merge = true, scope = none(GuildId))
  applied(eventName)

proc cascadeChannelMessages(cache: EntityCache; channelId: ChannelId;
                            observedAtMs: int64) =
  # `pairs` hides expired TTL entries without removing them, so purge first;
  # otherwise an expired message would be skipped by the cascade yet still be
  # counted by `messageCount`, leaving an expired remnant after the delete.
  discard cache.messages.purgeExpired(observedAtMs)
  var stale: seq[MessageKey]
  for key, _ in cache.messages.pairs(observedAtMs):
    if key.channelId == channelId:
      stale.add key
  for key in stale:
    cache.messages.del(key)

proc cascadeGuildDelete(cache: EntityCache; guildId: GuildId;
                        observedAtMs: int64) =
  # Cascade is driven by the internal scope recorded on each value, so it holds
  # even if the channel store is disabled or has evicted the channel, and no
  # reverse index survives an eviction. Purge every touched store first so an
  # expired-but-unpurged entry is neither skipped by the cascade nor left behind
  # to inflate a count. Keys are collected before deletion so no store is mutated
  # mid-iteration.
  discard cache.guilds.purgeExpired(observedAtMs)
  discard cache.channels.purgeExpired(observedAtMs)
  discard cache.members.purgeExpired(observedAtMs)
  discard cache.presences.purgeExpired(observedAtMs)
  discard cache.messages.purgeExpired(observedAtMs)
  cache.guilds.del(guildId)

  var staleChannels: seq[ChannelId]
  for channelId, snapshot in cache.channels.pairs(observedAtMs):
    if snapshot.value.guildId == some(guildId):
      staleChannels.add channelId
  for channelId in staleChannels:
    cache.channels.del(channelId)

  var staleMembers: seq[MemberKey]
  for key, _ in cache.members.pairs(observedAtMs):
    if key.guildId == guildId:
      staleMembers.add key
  for key in staleMembers:
    cache.members.del(key)

  var stalePresences: seq[PresenceKey]
  for key, _ in cache.presences.pairs(observedAtMs):
    if key.guildId == guildId:
      stalePresences.add key
  for key in stalePresences:
    cache.presences.del(key)

  var staleMessages: seq[MessageKey]
  for key, snapshot in cache.messages.pairs(observedAtMs):
    if snapshot.value.guildId == some(guildId):
      staleMessages.add key
  for key in staleMessages:
    cache.messages.del(key)

proc applyGuildDelete(cache: EntityCache; eventName: string; payload: JsonNode;
                      observedAtMs: int64): CacheApplyResult =
  let guildId = snowflake(GuildId, payload{"id"})
  if guildId.isNone:
    return malformed(eventName, "guild delete payload is missing a string id")
  # Discord sends `unavailable: true` for an outage in which the app was not
  # removed; the guild's data must be retained, only marked unavailable. A
  # present but non-boolean `unavailable` is malformed, not silently a removal.
  let unavailable = payload.optionalBoolField("unavailable")
  if unavailable.state == ofsInvalid:
    return malformed(eventName, "guild unavailable is present but not a boolean")
  if unavailable.state == ofsPresent and unavailable.value:
    cache.guilds.upsert(
      guildId.get, payload, observedAtMs, merge = true, scope = none(GuildId))
    return applied(eventName)
  cache.cascadeGuildDelete(guildId.get, observedAtMs)
  applied(eventName)

proc applyChannelDelete(cache: EntityCache; eventName: string;
                        payload: JsonNode; observedAtMs: int64):
    CacheApplyResult =
  let channelId = snowflake(ChannelId, payload{"id"})
  if channelId.isNone:
    return malformed(eventName, "channel delete payload is missing a string id")
  cache.channels.del(channelId.get)
  # Drop expired channel remnants so `channelCount` reflects only live entries
  # after the delete, then cascade this channel's messages.
  discard cache.channels.purgeExpired(observedAtMs)
  cache.cascadeChannelMessages(channelId.get, observedAtMs)
  applied(eventName)

proc applyMemberRemove(cache: EntityCache; eventName: string; payload: JsonNode):
    CacheApplyResult =
  let guildId = snowflake(GuildId, payload{"guild_id"})
  let userId = snowflake(UserId, payload{"user", "id"})
  if guildId.isNone:
    return malformed(eventName, "member remove payload is missing a guild id")
  if userId.isNone:
    return malformed(eventName, "member remove payload is missing a user id")
  cache.members.del(memberKey(guildId.get, userId.get))
  applied(eventName)

proc applyMessageDelete(cache: EntityCache; eventName: string;
                        payload: JsonNode): CacheApplyResult =
  let channelId = snowflake(ChannelId, payload{"channel_id"})
  let messageId = snowflake(MessageId, payload{"id"})
  if channelId.isNone:
    return malformed(eventName, "message delete payload is missing a channel id")
  if messageId.isNone:
    return malformed(eventName, "message delete payload is missing a message id")
  cache.messages.del(messageKey(channelId.get, messageId.get))
  applied(eventName)

proc applyMessageDeleteBulk(cache: EntityCache; eventName: string;
                            payload: JsonNode): CacheApplyResult =
  let channelId = snowflake(ChannelId, payload{"channel_id"})
  if channelId.isNone:
    return malformed(eventName, "bulk delete payload is missing a channel id")
  let ids = payload{"ids"}
  if ids.isNil or ids.kind != JArray:
    return malformed(eventName, "bulk delete payload is missing an ids array")
  var messageIds: seq[MessageId]
  for element in ids:
    let messageId = snowflake(MessageId, element)
    if messageId.isNone:
      return malformed(eventName, "bulk delete ids contain a malformed entry")
    messageIds.add messageId.get
  for messageId in messageIds:
    cache.messages.del(messageKey(channelId.get, messageId))
  applied(eventName)

proc applyGuildMembersChunk(cache: EntityCache; eventName: string;
                            payload: JsonNode; observedAtMs: int64):
    CacheApplyResult =
  let guildId = snowflake(GuildId, payload{"guild_id"})
  if guildId.isNone:
    return malformed(eventName, "member chunk is missing a guild id")
  # The members array is required and validated in full before any mutation, so
  # a single malformed member rejects the whole chunk.
  let membersNode = payload{"members"}
  if membersNode.isNil or membersNode.kind != JArray:
    return malformed(eventName, "member chunk members is not an array")
  let members = childUsers(membersNode)
  if members.isNone:
    return malformed(eventName, "member chunk members has a malformed entry")
  for (userId, node) in members.get:
    cache.members.upsert(memberKey(guildId.get, userId), node, observedAtMs,
      merge = false, scope = some(guildId.get))
  applied(eventName)

proc applyThreadListSync(cache: EntityCache; eventName: string;
                         payload: JsonNode; observedAtMs: int64):
    CacheApplyResult =
  let guildId = snowflake(GuildId, payload{"guild_id"})
  if guildId.isNone:
    return malformed(eventName, "thread list sync is missing a guild id")

  # `channel_ids` absent syncs the whole guild's active threads; present scopes
  # the sync to those parent channels; present-but-malformed is an error.
  let channelIdsNode = payload{"channel_ids"}
  var scoped = false
  var parents: HashSet[ChannelId]
  if not channelIdsNode.isNil:
    if channelIdsNode.kind != JArray:
      return malformed(eventName, "thread list sync channel_ids is not an array")
    for element in channelIdsNode:
      let parentId = snowflake(ChannelId, element)
      if parentId.isNone:
        return malformed(eventName,
          "thread list sync channel_ids has a malformed entry")
      parents.incl parentId.get
    scoped = true

  let threadsNode = payload{"threads"}
  if threadsNode.isNil or threadsNode.kind != JArray:
    return malformed(eventName, "thread list sync threads is not an array")
  let threads = childChannels(threadsNode)
  if threads.isNone:
    return malformed(eventName, "thread list sync threads has a malformed entry")
  var synced: HashSet[ChannelId]
  for (channelId, _) in threads.get:
    synced.incl channelId

  # Reconcile active threads: delete cached threads under this guild (and, when
  # scoped, under the given parents) that the authoritative sync omitted, while
  # preserving non-thread channels. Purge expired first so none lingers uncounted.
  discard cache.channels.purgeExpired(observedAtMs)
  var stale: seq[ChannelId]
  for channelId, snapshot in cache.channels.pairs(observedAtMs):
    if snapshot.value.guildId != some(guildId.get) or channelId in synced:
      continue
    var node: JsonNode
    try:
      node = parseJson(snapshot.value.payloadJson)
    except CatchableError:
      continue
    if not isThreadType(node{"type"}.getInt(-1)):
      continue
    if scoped:
      let parentId = snowflake(ChannelId, node{"parent_id"})
      if parentId.isNone or parentId.get notin parents:
        continue
    stale.add channelId
  for channelId in stale:
    cache.channels.del(channelId)

  for (channelId, node) in threads.get:
    cache.channels.upsert(
      channelId, node, observedAtMs, merge = false, scope = some(guildId.get))
  applied(eventName)

proc apply*(cache: EntityCache; eventName: string; payload: JsonNode;
            observedAtMs: int64): CacheApplyResult {.raises: [].} =
  ## Applies one dispatch event's `d` payload at `observedAtMs`.
  ##
  ## Returns `caIgnored` for uncached event names, `caMalformed` (caching
  ## nothing) for a non-object payload, a missing required identifier, or a
  ## malformed nested array, and `caApplied` when the event stores, merges, or
  ## deletes snapshots. It never raises, performs no I/O, and never exposes
  ## payload or exception text.
  if cache.isNil:
    return malformed(eventName, "entity cache is not initialized")
  if payload.isNil or payload.kind != JObject:
    return malformed(eventName, "event payload is not a JSON object")
  try:
    case eventName
    of "GUILD_CREATE":
      cache.applyGuildCreate(eventName, payload, observedAtMs)
    of "GUILD_UPDATE":
      cache.applyGuildUpdate(eventName, payload, observedAtMs)
    of "GUILD_DELETE":
      cache.applyGuildDelete(eventName, payload, observedAtMs)
    of "CHANNEL_CREATE", "THREAD_CREATE":
      cache.applyChannel(eventName, payload, observedAtMs, merge = false)
    of "CHANNEL_UPDATE", "THREAD_UPDATE":
      cache.applyChannel(eventName, payload, observedAtMs, merge = true)
    of "CHANNEL_DELETE", "THREAD_DELETE":
      cache.applyChannelDelete(eventName, payload, observedAtMs)
    of "GUILD_MEMBER_ADD":
      cache.applyMember(eventName, payload, observedAtMs, merge = false)
    of "GUILD_MEMBER_UPDATE":
      cache.applyMember(eventName, payload, observedAtMs, merge = true)
    of "GUILD_MEMBER_REMOVE":
      cache.applyMemberRemove(eventName, payload)
    of "GUILD_MEMBERS_CHUNK":
      cache.applyGuildMembersChunk(eventName, payload, observedAtMs)
    of "THREAD_LIST_SYNC":
      cache.applyThreadListSync(eventName, payload, observedAtMs)
    of "MESSAGE_CREATE":
      cache.applyMessage(eventName, payload, observedAtMs, merge = false)
    of "MESSAGE_UPDATE":
      cache.applyMessage(eventName, payload, observedAtMs, merge = true)
    of "MESSAGE_DELETE":
      cache.applyMessageDelete(eventName, payload)
    of "MESSAGE_DELETE_BULK":
      cache.applyMessageDeleteBulk(eventName, payload)
    of "PRESENCE_UPDATE":
      cache.applyPresence(eventName, payload, observedAtMs)
    else:
      ignored(eventName)
  except CatchableError:
    # A stored snapshot is always valid serialized JSON, so this only guards
    # against an unexpected internal fault; it still redacts to a payload-free
    # note.
    malformed(eventName, "event payload could not be cached")

proc applyRaw*(cache: EntityCache; eventName: string; rawPayload: string):
    CacheApplyResult {.raises: [].} =
  ## Parses a raw `d` payload string and applies it at the cache clock's instant.
  ##
  ## An unparseable payload or a nil cache is reported as `caMalformed` without
  ## exposing the input. This is the entry point used by the dispatch adapter.
  if cache.isNil:
    return malformed(eventName, "entity cache is not initialized")
  let observedAtMs = cache.clock()
  var payload: JsonNode
  try:
    payload = parseJson(rawPayload)
  except CatchableError:
    return malformed(eventName, "event payload is not valid JSON")
  cache.apply(eventName, payload, observedAtMs)

# --- lookups and stats -------------------------------------------------------

proc lookup[K](store: var CacheStore[K, CachedEntity]; key: K; nowMs: int64):
    Option[CacheLookup] {.raises: [].} =
  let snapshot = store.get(key, nowMs)
  if snapshot.isNone:
    return none(CacheLookup)
  var decoded: JsonNode
  try:
    decoded = parseJson(snapshot.get.value.payloadJson)
  except CatchableError:
    # A stored value is always JSON this module serialized, so a parse failure is
    # an impossible internal fault; fail closed rather than raise into a handler.
    return none(CacheLookup)
  some(CacheLookup(
    revision: snapshot.get.revision,
    observedAtMs: snapshot.get.observedAtMs,
    payload: decoded))

proc guild*(cache: EntityCache; id: GuildId): Option[CacheLookup]
    {.raises: [].} =
  ## Returns a fresh decoded guild snapshot, or `none` on a miss, expiry, or a
  ## nil cache. Safe to call from within a `raises: []` dispatch handler.
  if cache.isNil:
    return none(CacheLookup)
  cache.guilds.lookup(id, cache.clock())

proc channel*(cache: EntityCache; id: ChannelId): Option[CacheLookup]
    {.raises: [].} =
  ## Returns a fresh decoded channel or thread snapshot.
  if cache.isNil:
    return none(CacheLookup)
  cache.channels.lookup(id, cache.clock())

proc member*(cache: EntityCache; guildId: GuildId; userId: UserId):
    Option[CacheLookup] {.raises: [].} =
  ## Returns a fresh decoded guild-member snapshot.
  if cache.isNil:
    return none(CacheLookup)
  cache.members.lookup(memberKey(guildId, userId), cache.clock())

proc message*(cache: EntityCache; channelId: ChannelId; messageId: MessageId):
    Option[CacheLookup] {.raises: [].} =
  ## Returns a fresh decoded message snapshot.
  if cache.isNil:
    return none(CacheLookup)
  cache.messages.lookup(messageKey(channelId, messageId), cache.clock())

proc presence*(cache: EntityCache; guildId: GuildId; userId: UserId):
    Option[CacheLookup] {.raises: [].} =
  ## Returns a fresh decoded presence snapshot.
  if cache.isNil:
    return none(CacheLookup)
  cache.presences.lookup(presenceKey(guildId, userId), cache.clock())

func guildCount*(cache: EntityCache): int =
  ## Number of retained guild entries, including unpurged TTL entries.
  if cache.isNil: 0 else: cache.guilds.len
func channelCount*(cache: EntityCache): int =
  ## Number of retained channel and thread entries.
  if cache.isNil: 0 else: cache.channels.len
func memberCount*(cache: EntityCache): int =
  ## Number of retained member entries.
  if cache.isNil: 0 else: cache.members.len
func messageCount*(cache: EntityCache): int =
  ## Number of retained message entries.
  if cache.isNil: 0 else: cache.messages.len
func presenceCount*(cache: EntityCache): int =
  ## Number of retained presence entries.
  if cache.isNil: 0 else: cache.presences.len

func stats*(cache: EntityCache): EntityCacheStats =
  ## Returns cumulative per-domain hit/miss/eviction counters.
  if cache.isNil:
    return EntityCacheStats()
  EntityCacheStats(
    guilds: cache.guilds.stats,
    channels: cache.channels.stats,
    members: cache.members.stats,
    messages: cache.messages.stats,
    presences: cache.presences.stats)

proc clear*(cache: EntityCache) =
  ## Removes every retained entry from all domains without changing policy.
  if cache.isNil:
    return
  cache.guilds.clear()
  cache.channels.clear()
  cache.members.clear()
  cache.messages.clear()
  cache.presences.clear()

# --- dispatch-handler adapter ------------------------------------------------

proc cachingHandler*(cache: EntityCache; inner: GatewayDispatchHandler;
                     observer: CacheApplyObserver = nil): GatewayDispatchHandler =
  ## Wraps `inner` so the cache is updated before the user handler runs.
  ##
  ## For each event the raw payload is applied synchronously (so a handler always
  ## observes the already-updated cache), the redaction-safe result is reported
  ## to `observer`, and then the event is delivered to `inner` unchanged. A cache
  ## decode or application failure is reported through `observer` only; it never
  ## blocks raw delivery and is never surfaced on the returned future, which
  ## carries exactly the inner handler's own outcome.
  if cache.isNil:
    raise newException(ValueError, "caching handler requires an entity cache")
  if inner.isNil:
    raise newException(ValueError, "caching handler requires an inner handler")
  result = proc(event: DispatchEvent): Future[void] {.closure, gcsafe,
      raises: [].} =
    let res = cache.applyRaw(event.name, event.payload)
    if not observer.isNil:
      observer(res)
    inner(event)
