import std/[json, options, unittest]

import chronos

import cordnim/cache
import cordnim/core/ids
import cordnim/gateway/entity_cache
import cordnim/gateway/dispatch_runtime
import cordnim/gateway/session

proc clockBox(start = 10_000'i64): ref int64 =
  result = new(int64)
  result[] = start

proc clockOf(box: ref int64): MonotonicClock =
  proc(): int64 {.gcsafe, raises: [].} = box[]

proc fullPolicies(): CachePolicies =
  CachePolicies(
    guilds: fullCache(), channels: fullCache(), members: fullCache(),
    messages: fullCache(), presences: fullCache())

proc freshCache(): EntityCache =
  newEntityCache(fullPolicies(), clockOf(clockBox()))

proc gid(value: uint64): GuildId = GuildId(value)
proc cid(value: uint64): ChannelId = ChannelId(value)
proc uid(value: uint64): UserId = UserId(value)
proc mid(value: uint64): MessageId = MessageId(value)

suite "entity cache apply and lookup":
  test "stores a lossless snapshot and returns a fresh, non-aliased node":
    let cache = freshCache()
    let res = cache.apply("GUILD_CREATE",
      %*{"id": "1", "name": "Guild", "future_field": {"v": 1}}, 1_000)
    check res.outcome == caApplied

    let first = cache.guild(gid(1))
    check first.isSome
    check first.get.revision == 1
    check first.get.observedAtMs == 1_000
    check first.get.payload["name"].getStr() == "Guild"
    check first.get.payload["future_field"]["v"].getInt() == 1

    # Mutating the decoded payload must never reach cache state.
    first.get.payload["name"] = %"HACKED"
    first.get.payload.delete("future_field")
    let second = cache.guild(gid(1))
    check second.get.payload["name"].getStr() == "Guild"
    check second.get.payload["future_field"]["v"].getInt() == 1

  test "merges partial updates, preserving prior and unknown fields":
    let cache = freshCache()
    discard cache.apply("GUILD_CREATE",
      %*{"id": "1", "name": "G", "icon": "a", "future_a": 1}, 1_000)
    let res = cache.apply("GUILD_UPDATE",
      %*{"id": "1", "name": "G2", "future_b": 2}, 2_000)
    check res.outcome == caApplied

    let snap = cache.guild(gid(1)).get
    check snap.payload["name"].getStr() == "G2"     # updated
    check snap.payload["icon"].getStr() == "a"      # preserved
    check snap.payload["future_a"].getInt() == 1    # preserved unknown
    check snap.payload["future_b"].getInt() == 2    # new unknown
    check snap.revision == 2

  test "GUILD_CREATE populates nested domains and stays lossless":
    let cache = freshCache()
    let res = cache.apply("GUILD_CREATE", %*{
      "id": "1", "name": "G", "mystery": "keep",
      "channels": [
        {"id": "10", "name": "general", "extra": "c-unknown"},
        {"id": "11", "type": 0}],
      "threads": [{"id": "20", "name": "t"}],
      "members": [{"user": {"id": "42"}, "nick": "n", "extra": "m-unknown"}],
      "presences": [{"user": {"id": "42"}, "status": "online"}]
    }, 1_000)
    check res.outcome == caApplied

    # The guild payload keeps its nested arrays verbatim.
    let guild = cache.guild(gid(1)).get.payload
    check guild["mystery"].getStr() == "keep"
    check guild["channels"].len == 2

    # Children are indexed with their unknown fields preserved, and the internal
    # guild scope is never injected into the returned raw payload.
    check cache.channelCount == 3                     # channels + threads
    let channel = cache.channel(cid(10)).get.payload
    check channel["name"].getStr() == "general"
    check channel["extra"].getStr() == "c-unknown"
    check not channel.hasKey("guild_id")
    check cache.channel(cid(20)).isSome               # thread indexed too
    let member = cache.member(gid(1), uid(42)).get.payload
    check member["nick"].getStr() == "n"
    check member["extra"].getStr() == "m-unknown"
    check cache.presence(gid(1), uid(42)).get.payload["status"].getStr() ==
      "online"

    # Deleting the guild cascades children indexed only by internal scope.
    discard cache.apply("GUILD_DELETE", %*{"id": "1"}, 2_000)
    check cache.channel(cid(10)).isNone
    check cache.channel(cid(20)).isNone
    check cache.member(gid(1), uid(42)).isNone
    check cache.presence(gid(1), uid(42)).isNone

  test "channels and threads share one domain with create/update/delete":
    let cache = freshCache()
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "10", "guild_id": "1", "name": "c"}, 1_000)
    discard cache.apply("THREAD_CREATE",
      %*{"id": "11", "guild_id": "1", "name": "t"}, 1_000)
    check cache.channelCount == 2

    discard cache.apply("CHANNEL_UPDATE", %*{"id": "10", "topic": "x"}, 2_000)
    let c10 = cache.channel(cid(10)).get
    check c10.payload["name"].getStr() == "c"       # merged
    check c10.payload["topic"].getStr() == "x"

    discard cache.apply("CHANNEL_DELETE", %*{"id": "10"}, 3_000)
    discard cache.apply("THREAD_DELETE", %*{"id": "11"}, 3_000)
    check cache.channel(cid(10)).isNone
    check cache.channelCount == 0

  test "members are keyed by guild and user with merge on update":
    let cache = freshCache()
    discard cache.apply("GUILD_MEMBER_ADD",
      %*{"guild_id": "1", "user": {"id": "42"}, "nick": "n"}, 1_000)
    check cache.member(gid(1), uid(42)).get.payload["nick"].getStr() == "n"

    discard cache.apply("GUILD_MEMBER_UPDATE",
      %*{"guild_id": "1", "user": {"id": "42"}, "roles": ["r1"]}, 2_000)
    let m = cache.member(gid(1), uid(42)).get
    check m.payload["nick"].getStr() == "n"          # preserved
    check m.payload["roles"][0].getStr() == "r1"     # merged

    discard cache.apply("GUILD_MEMBER_REMOVE",
      %*{"guild_id": "1", "user": {"id": "42"}}, 3_000)
    check cache.member(gid(1), uid(42)).isNone

  test "messages are keyed by channel and message with merge on update":
    let cache = freshCache()
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "100", "channel_id": "10", "content": "hi"}, 1_000)
    check cache.message(cid(10), mid(100)).get.payload["content"].getStr() == "hi"

    discard cache.apply("MESSAGE_UPDATE",
      %*{"id": "100", "channel_id": "10", "edited_timestamp": "t"}, 2_000)
    let msg = cache.message(cid(10), mid(100)).get
    check msg.payload["content"].getStr() == "hi"    # preserved
    check msg.payload["edited_timestamp"].getStr() == "t"

    discard cache.apply("MESSAGE_DELETE",
      %*{"id": "100", "channel_id": "10"}, 3_000)
    check cache.message(cid(10), mid(100)).isNone

  test "MESSAGE_DELETE_BULK removes each listed message in the channel":
    let cache = freshCache()
    for id in ["1", "2", "3"]:
      discard cache.apply("MESSAGE_CREATE",
        %*{"id": id, "channel_id": "10", "guild_id": "1"}, 1_000)
    let res = cache.apply("MESSAGE_DELETE_BULK",
      %*{"channel_id": "10", "ids": ["1", "2"]}, 2_000)
    check res.outcome == caApplied
    check cache.message(cid(10), mid(1)).isNone
    check cache.message(cid(10), mid(2)).isNone
    check cache.message(cid(10), mid(3)).isSome
    check cache.messageCount == 1

    check cache.apply("MESSAGE_DELETE_BULK",
      %*{"channel_id": "10", "ids": "nope"}, 3_000).outcome == caMalformed
    check cache.apply("MESSAGE_DELETE_BULK",
      %*{"channel_id": "10", "ids": ["bad"]}, 3_000).outcome == caMalformed
    check cache.messageCount == 1                    # malformed bulk changed nothing

  test "presence updates upsert-merge by guild and user":
    let cache = freshCache()
    discard cache.apply("PRESENCE_UPDATE",
      %*{"guild_id": "1", "user": {"id": "42"}, "status": "online"}, 1_000)
    discard cache.apply("PRESENCE_UPDATE",
      %*{"guild_id": "1", "user": {"id": "42"}, "status": "idle",
         "activities": [{"name": "x"}]}, 2_000)
    let p = cache.presence(gid(1), uid(42)).get
    check p.payload["status"].getStr() == "idle"
    check p.payload["activities"][0]["name"].getStr() == "x"

  test "channel and thread delete cascade that channel's messages":
    let cache = freshCache()
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "10", "guild_id": "1"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "100", "channel_id": "10", "guild_id": "1"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "101", "channel_id": "10"}, 1_000)      # no guild_id
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "200", "channel_id": "99"}, 1_000)      # other channel
    discard cache.apply("CHANNEL_DELETE", %*{"id": "10"}, 2_000)
    check cache.channel(cid(10)).isNone
    check cache.message(cid(10), mid(100)).isNone      # cascaded by channel key
    check cache.message(cid(10), mid(101)).isNone      # even without guild_id
    check cache.message(cid(99), mid(200)).isSome      # unrelated channel kept

  test "guild delete cascades only its own guild-scoped data":
    let cache = freshCache()
    discard cache.apply("GUILD_CREATE", %*{"id": "1"}, 1_000)
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "10", "guild_id": "1"}, 1_000)
    discard cache.apply("THREAD_CREATE", %*{"id": "11", "guild_id": "1"}, 1_000)
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "20", "guild_id": "2"}, 1_000)             # other guild
    discard cache.apply("CHANNEL_CREATE", %*{"id": "30"}, 1_000)  # DM-like
    discard cache.apply("GUILD_MEMBER_ADD",
      %*{"guild_id": "1", "user": {"id": "42"}}, 1_000)
    discard cache.apply("GUILD_MEMBER_ADD",
      %*{"guild_id": "2", "user": {"id": "43"}}, 1_000)
    discard cache.apply("PRESENCE_UPDATE",
      %*{"guild_id": "1", "user": {"id": "42"}, "status": "online"}, 1_000)
    discard cache.apply("PRESENCE_UPDATE",
      %*{"guild_id": "2", "user": {"id": "43"}, "status": "online"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "100", "channel_id": "10", "guild_id": "1"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "200", "channel_id": "20", "guild_id": "2"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "300", "channel_id": "30"}, 1_000)         # DM message

    let res = cache.apply("GUILD_DELETE", %*{"id": "1"}, 2_000)
    check res.outcome == caApplied

    check cache.guild(gid(1)).isNone
    check cache.channel(cid(10)).isNone
    check cache.channel(cid(11)).isNone
    check cache.channel(cid(20)).isSome                   # other guild kept
    check cache.channel(cid(30)).isSome                   # DM kept
    check cache.member(gid(1), uid(42)).isNone
    check cache.member(gid(2), uid(43)).isSome
    check cache.presence(gid(1), uid(42)).isNone
    check cache.presence(gid(2), uid(43)).isSome
    check cache.message(cid(10), mid(100)).isNone         # guild-scoped message
    check cache.message(cid(20), mid(200)).isSome         # other guild kept
    check cache.message(cid(30), mid(300)).isSome         # DM kept

  test "guild message cascade does not depend on the channel store":
    var policies = fullPolicies()
    policies.channels = disabledCache()                   # channels never retained
    let cache = newEntityCache(policies, clockOf(clockBox()))
    discard cache.apply("GUILD_CREATE", %*{"id": "1"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "100", "channel_id": "10", "guild_id": "1"}, 1_000)
    check cache.channelCount == 0                          # disabled
    check cache.messageCount == 1
    discard cache.apply("GUILD_DELETE", %*{"id": "1"}, 2_000)
    check cache.message(cid(10), mid(100)).isNone          # cascaded by scope

  test "an unavailable guild delete retains data as an outage":
    let cache = freshCache()
    discard cache.apply("GUILD_CREATE", %*{"id": "1", "name": "G"}, 1_000)
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "10", "guild_id": "1"}, 1_000)
    let res = cache.apply("GUILD_DELETE",
      %*{"id": "1", "unavailable": true}, 2_000)
    check res.outcome == caApplied
    check cache.guild(gid(1)).isSome
    check cache.guild(gid(1)).get.payload["unavailable"].getBool()
    check cache.guild(gid(1)).get.payload["name"].getStr() == "G"
    check cache.channel(cid(10)).isSome                   # not cascaded

suite "entity cache retention policies":
  test "a disabled policy retains nothing":
    var policies = fullPolicies()
    policies.members = disabledCache()
    let cache = newEntityCache(policies, clockOf(clockBox()))
    let res = cache.apply("GUILD_MEMBER_ADD",
      %*{"guild_id": "1", "user": {"id": "42"}}, 1_000)
    check res.outcome == caApplied           # recognized, but nothing retained
    check cache.memberCount == 0
    check cache.member(gid(1), uid(42)).isNone

  test "LRU eviction is deterministic":
    var policies = fullPolicies()
    policies.channels = lruCache(2)
    let cache = newEntityCache(policies, clockOf(clockBox()))
    discard cache.apply("CHANNEL_CREATE", %*{"id": "1", "guild_id": "9"}, 1_000)
    discard cache.apply("CHANNEL_CREATE", %*{"id": "2", "guild_id": "9"}, 1_001)
    discard cache.apply("CHANNEL_CREATE", %*{"id": "3", "guild_id": "9"}, 1_002)
    check cache.channelCount == 2
    check cache.channel(cid(1)).isNone       # least recently used, evicted
    check cache.channel(cid(2)).isSome
    check cache.channel(cid(3)).isSome
    check cache.stats.channels.evictions >= 1

  test "TTL expiry is deterministic under the injected clock":
    var policies = fullPolicies()
    policies.messages = ttlCache(1_000, 10)
    let box = clockBox(1_000)
    let cache = newEntityCache(policies, clockOf(box))
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "100", "channel_id": "10"}, 1_000)
    box[] = 1_500
    check cache.message(cid(10), mid(100)).isSome    # age 500 < ttl
    box[] = 2_500
    check cache.message(cid(10), mid(100)).isNone    # age 1500 >= ttl
    check cache.messageCount == 0                    # expired entry purged

  test "channel delete leaves message counts free of expired remnants":
    var policies = fullPolicies()
    policies.channels = ttlCache(1_000, 100)
    policies.messages = ttlCache(1_000, 100)
    let box = clockBox(1_000)
    let cache = newEntityCache(policies, clockOf(box))
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "10", "guild_id": "1"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "100", "channel_id": "10", "guild_id": "1"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "101", "channel_id": "10", "guild_id": "1"}, 1_000)
    box[] = 3_000                                    # entries now expired
    # `len`-based counts still include expired-but-unpurged entries pre-delete.
    check cache.messageCount == 2
    discard cache.apply("CHANNEL_DELETE", %*{"id": "10"}, 3_000)
    check cache.messageCount == 0                    # no expired remnant left
    check cache.channelCount == 0

  test "guild delete leaves all cascaded counts free of expired remnants":
    var policies = fullPolicies()
    policies.channels = ttlCache(1_000, 100)
    policies.messages = ttlCache(1_000, 100)
    policies.members = ttlCache(1_000, 100)
    policies.presences = ttlCache(1_000, 100)
    let box = clockBox(1_000)
    let cache = newEntityCache(policies, clockOf(box))
    discard cache.apply("GUILD_CREATE", %*{"id": "1"}, 1_000)
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "10", "guild_id": "1"}, 1_000)
    discard cache.apply("MESSAGE_CREATE",
      %*{"id": "100", "channel_id": "10", "guild_id": "1"}, 1_000)
    discard cache.apply("GUILD_MEMBER_ADD",
      %*{"guild_id": "1", "user": {"id": "42"}}, 1_000)
    discard cache.apply("PRESENCE_UPDATE",
      %*{"guild_id": "1", "user": {"id": "42"}, "status": "online"}, 1_000)
    box[] = 3_000                                    # every TTL entry expired
    check cache.channelCount == 1                    # unpurged remnants counted
    check cache.messageCount == 1
    check cache.memberCount == 1
    check cache.presenceCount == 1
    discard cache.apply("GUILD_DELETE", %*{"id": "1"}, 3_000)
    check cache.channelCount == 0
    check cache.messageCount == 0
    check cache.memberCount == 0
    check cache.presenceCount == 0
    check cache.guildCount == 0

suite "entity cache event classification":
  test "unknown events are ignored and cache nothing":
    let cache = freshCache()
    let res = cache.apply("TYPING_START",
      %*{"channel_id": "10", "user_id": "42"}, 1_000)
    check res.outcome == caIgnored
    check cache.channelCount == 0

  test "malformed events are rejected and cache nothing":
    let cache = freshCache()
    check cache.apply("GUILD_CREATE", %*[1, 2, 3], 1_000).outcome == caMalformed
    check cache.apply("GUILD_CREATE", %*{"name": "x"}, 1_000).outcome == caMalformed
    check cache.apply("GUILD_MEMBER_ADD",
      %*{"guild_id": "1"}, 1_000).outcome == caMalformed
    check cache.apply("MESSAGE_CREATE",
      %*{"id": "1"}, 1_000).outcome == caMalformed
    check cache.applyRaw("MESSAGE_CREATE", "{ not json").outcome == caMalformed
    check cache.guildCount == 0
    check cache.memberCount == 0
    check cache.messageCount == 0

  test "malformed nested arrays reject the whole guild atomically":
    let cache = freshCache()
    check cache.apply("GUILD_CREATE",
      %*{"id": "1", "channels": "notarray"}, 1_000).outcome == caMalformed
    check cache.apply("GUILD_CREATE",
      %*{"id": "1", "channels": [123]}, 1_000).outcome == caMalformed
    check cache.apply("GUILD_CREATE",
      %*{"id": "1", "channels": [{"name": "x"}]}, 1_000).outcome == caMalformed
    check cache.apply("GUILD_CREATE",
      %*{"id": "1", "members": [{"nick": "x"}]}, 1_000).outcome == caMalformed
    # Nothing from any rejected guild was cached.
    check cache.guildCount == 0
    check cache.channelCount == 0
    check cache.memberCount == 0

  test "a nil cache is handled explicitly by apply, applyRaw, and lookups":
    let cache = EntityCache(nil)
    check cache.apply("GUILD_CREATE", %*{"id": "1"}, 1_000).outcome == caMalformed
    check cache.applyRaw("GUILD_CREATE", "{}").outcome == caMalformed
    check cache.guild(gid(1)).isNone
    check cache.guildCount == 0

suite "entity cache gateway protocol semantics":
  test "GUILD_MEMBERS_CHUNK populates members with unknown fields":
    let cache = freshCache()
    let res = cache.apply("GUILD_MEMBERS_CHUNK", %*{
      "guild_id": "1",
      "members": [
        {"user": {"id": "42"}, "nick": "a", "extra": "x"},
        {"user": {"id": "43"}, "nick": "b"}]
    }, 1_000)
    check res.outcome == caApplied
    check cache.memberCount == 2
    check cache.member(gid(1), uid(42)).get.payload["nick"].getStr() == "a"
    check cache.member(gid(1), uid(42)).get.payload["extra"].getStr() == "x"
    check cache.member(gid(1), uid(43)).isSome

  test "GUILD_MEMBERS_CHUNK rejects a malformed members array atomically":
    let cache = freshCache()
    check cache.apply("GUILD_MEMBERS_CHUNK", %*{
      "guild_id": "1",
      "members": [{"user": {"id": "42"}}, {"nick": "no user"}]
    }, 1_000).outcome == caMalformed
    check cache.apply("GUILD_MEMBERS_CHUNK",
      %*{"guild_id": "1", "members": "nope"}, 1_000).outcome == caMalformed
    check cache.apply("GUILD_MEMBERS_CHUNK",
      %*{"members": []}, 1_000).outcome == caMalformed        # missing guild_id
    check cache.memberCount == 0                              # nothing cached

  test "THREAD_LIST_SYNC upserts threads and syncs the whole active set":
    let cache = freshCache()
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "5", "guild_id": "1", "type": 0}, 1_000)       # regular channel
    discard cache.apply("THREAD_CREATE",
      %*{"id": "10", "guild_id": "1", "type": 11, "parent_id": "5"}, 1_000)
    discard cache.apply("THREAD_CREATE",
      %*{"id": "11", "guild_id": "1", "type": 11, "parent_id": "5"}, 1_000)
    let res = cache.apply("THREAD_LIST_SYNC", %*{
      "guild_id": "1",
      "threads": [
        {"id": "10", "type": 11, "parent_id": "5"},
        {"id": "12", "type": 11, "parent_id": "5"}]
    }, 2_000)
    check res.outcome == caApplied
    check cache.channel(cid(10)).isSome        # in sync, kept
    check cache.channel(cid(11)).isNone        # active thread omitted -> deleted
    check cache.channel(cid(12)).isSome        # new thread added
    check cache.channel(cid(5)).isSome         # non-thread channel preserved

  test "THREAD_LIST_SYNC scoped to channel_ids reconciles only those parents":
    let cache = freshCache()
    discard cache.apply("THREAD_CREATE",
      %*{"id": "10", "guild_id": "1", "type": 11, "parent_id": "100"}, 1_000)
    discard cache.apply("THREAD_CREATE",
      %*{"id": "11", "guild_id": "1", "type": 11, "parent_id": "100"}, 1_000)
    discard cache.apply("THREAD_CREATE",
      %*{"id": "20", "guild_id": "1", "type": 11, "parent_id": "200"}, 1_000)
    let res = cache.apply("THREAD_LIST_SYNC", %*{
      "guild_id": "1", "channel_ids": ["100"],
      "threads": [{"id": "10", "type": 11, "parent_id": "100"}]
    }, 2_000)
    check res.outcome == caApplied
    check cache.channel(cid(10)).isSome        # in sync, kept
    check cache.channel(cid(11)).isNone        # under 100, omitted -> deleted
    check cache.channel(cid(20)).isSome        # under 200, out of scope -> kept

  test "THREAD_LIST_SYNC with an empty list clears the guild's active threads":
    let cache = freshCache()
    discard cache.apply("THREAD_CREATE",
      %*{"id": "10", "guild_id": "1", "type": 11, "parent_id": "100"}, 1_000)
    discard cache.apply("CHANNEL_CREATE",
      %*{"id": "5", "guild_id": "1", "type": 0}, 1_000)
    let res = cache.apply("THREAD_LIST_SYNC",
      %*{"guild_id": "1", "threads": []}, 2_000)
    check res.outcome == caApplied
    check cache.channel(cid(10)).isNone        # active threads cleared
    check cache.channel(cid(5)).isSome         # non-thread channel preserved

  test "THREAD_LIST_SYNC rejects malformed channel_ids and threads":
    let cache = freshCache()
    check cache.apply("THREAD_LIST_SYNC",
      %*{"guild_id": "1", "channel_ids": "nope", "threads": []},
      1_000).outcome == caMalformed
    check cache.apply("THREAD_LIST_SYNC",
      %*{"guild_id": "1", "channel_ids": [123], "threads": []},
      1_000).outcome == caMalformed
    check cache.apply("THREAD_LIST_SYNC",
      %*{"guild_id": "1", "threads": [{"type": 11}]},
      1_000).outcome == caMalformed                          # thread missing id
    check cache.apply("THREAD_LIST_SYNC",
      %*{"threads": []}, 1_000).outcome == caMalformed        # missing guild_id

  test "an unavailable GUILD_CREATE merges and retains existing fields":
    let cache = freshCache()
    discard cache.apply("GUILD_CREATE",
      %*{"id": "1", "name": "G", "icon": "a"}, 1_000)
    let res = cache.apply("GUILD_CREATE",
      %*{"id": "1", "unavailable": true}, 2_000)
    check res.outcome == caApplied
    let guild = cache.guild(gid(1)).get.payload
    check guild["name"].getStr() == "G"        # retained, not erased
    check guild["icon"].getStr() == "a"
    check guild["unavailable"].getBool()       # merged flag

  test "an available GUILD_CREATE prunes channels omitted on recovery":
    let cache = freshCache()
    discard cache.apply("GUILD_CREATE",
      %*{"id": "1", "channels": [{"id": "10"}, {"id": "11"}]}, 1_000)
    check cache.channelCount == 2
    let res = cache.apply("GUILD_CREATE",
      %*{"id": "1", "channels": [{"id": "10"}, {"id": "12"}]}, 2_000)
    check res.outcome == caApplied
    check cache.channel(cid(10)).isSome
    check cache.channel(cid(11)).isNone        # stale channel removed
    check cache.channel(cid(12)).isSome
    check cache.channelCount == 2

  test "GUILD_CREATE recovery never prunes partial members or presences":
    let cache = freshCache()
    discard cache.apply("GUILD_CREATE", %*{
      "id": "1", "channels": [{"id": "10"}],
      "members": [{"user": {"id": "42"}}],
      "presences": [{"user": {"id": "42"}, "status": "online"}]}, 1_000)
    discard cache.apply("GUILD_MEMBER_ADD",
      %*{"guild_id": "1", "user": {"id": "99"}}, 1_500)
    # A recovery whose members list omits 99 must not prune it.
    let res = cache.apply("GUILD_CREATE", %*{
      "id": "1", "channels": [{"id": "10"}],
      "members": [{"user": {"id": "42"}}]}, 2_000)
    check res.outcome == caApplied
    check cache.member(gid(1), uid(99)).isSome      # partial members untouched
    check cache.member(gid(1), uid(42)).isSome
    check cache.presence(gid(1), uid(42)).isSome    # presences untouched

  test "present-but-malformed scope fields are rejected, not ignored":
    let cache = freshCache()
    check cache.apply("CHANNEL_CREATE",
      %*{"id": "10", "guild_id": 123}, 1_000).outcome == caMalformed
    check cache.apply("MESSAGE_CREATE",
      %*{"id": "1", "channel_id": "10", "guild_id": "abc"},
      1_000).outcome == caMalformed
    check cache.apply("GUILD_DELETE",
      %*{"id": "1", "unavailable": "yes"}, 1_000).outcome == caMalformed
    check cache.apply("GUILD_CREATE",
      %*{"id": "1", "unavailable": 1}, 1_000).outcome == caMalformed
    check cache.channelCount == 0
    check cache.messageCount == 0
    check cache.guildCount == 0

suite "entity cache dispatch adapter":
  test "applies the cache before the inner handler observes it":
    # Wrapped in a proc so the closures capture true locals, not test globals.
    proc scenario(): Future[(bool, CacheApplyOutcome, bool)] {.async.} =
      let cache = newEntityCache(fullPolicies(), clockOf(clockBox()))
      let observed = new(bool)
      observed[] = false
      let reported = new(CacheApplyOutcome)
      reported[] = caIgnored
      proc inner(event: DispatchEvent): Future[void] {.gcsafe, raises: [].} =
        discard event
        observed[] = cache.guild(gid(1)).isSome
        result = newFuture[void]("test.inner")
        result.complete()
      proc observer(res: CacheApplyResult) {.gcsafe, raises: [].} =
        reported[] = res.outcome
      let handler = cachingHandler(cache, inner, observer)
      let event = initDispatchEvent("GUILD_CREATE", ShardId(0),
        GatewaySequence(1), 0'u64, $(%*{"id": "1", "name": "G"}))
      await handler(event)
      return (observed[], reported[], cache.guild(gid(1)).isSome)

    let (observed, reported, present) = waitFor scenario()
    check observed                         # inner saw the applied guild
    check reported == caApplied
    check present

  test "delivers events and reports failure without blocking on cache errors":
    proc scenario(): Future[(int, CacheApplyOutcome, int)] {.async.} =
      let cache = newEntityCache(fullPolicies(), clockOf(clockBox()))
      let delivered = new(int)
      delivered[] = 0
      let reported = new(CacheApplyOutcome)
      reported[] = caApplied
      proc inner(event: DispatchEvent): Future[void] {.gcsafe, raises: [].} =
        discard event
        delivered[] = delivered[] + 1
        result = newFuture[void]("test.inner2")
        result.complete()
      proc observer(res: CacheApplyResult) {.gcsafe, raises: [].} =
        reported[] = res.outcome
      let handler = cachingHandler(cache, inner, observer)
      # Unparseable payload: cache fails, but the event is still delivered.
      let bad = initDispatchEvent("GUILD_CREATE", ShardId(0),
        GatewaySequence(1), 0'u64, "{ not json")
      await handler(bad)
      return (delivered[], reported[], cache.guildCount)

    let (delivered, reported, guildCount) = waitFor scenario()
    check delivered == 1
    check reported == caMalformed
    check guildCount == 0

  test "surfaces the inner handler's own failure on the returned future":
    proc scenario(): Future[bool] {.async.} =
      let cache = newEntityCache(fullPolicies(), clockOf(clockBox()))
      proc failing(event: DispatchEvent): Future[void] {.gcsafe, raises: [].} =
        discard event
        result = newFuture[void]("test.failing")
        result.fail(newException(ValueError, "inner boom"))
      let handler = cachingHandler(cache, failing)
      let event = initDispatchEvent("GUILD_CREATE", ShardId(0),
        GatewaySequence(1), 0'u64, $(%*{"id": "1"}))
      var raised = false
      try:
        await handler(event)
      except ValueError:
        raised = true
      # Cache application still succeeded even though the inner handler failed.
      return raised and cache.guild(gid(1)).isSome

    check waitFor scenario()
