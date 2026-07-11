## Optional in-memory cache for immutable snapshots and deterministic eviction.

import std/[options, tables]

import ./[policy, snapshots]

type
  CacheStats* = object ## Cumulative lookup and automatic-eviction counters.
    hits*: uint64 ## Successful mutating `get` calls.
    misses*: uint64 ## Missing or expired mutating `get` calls.
    evictions*: uint64 ## Entries removed by capacity or TTL enforcement.

  StoredSnapshot[T] = object
    snapshot: Snapshot[T]
    lastAccess: uint64

  CacheStore*[K, V] = object ## Policy-driven, process-local snapshot store.
    policy: CachePolicy
    entries: Table[K, StoredSnapshot[V]]
    accessClock: uint64
    nextRevision: uint64
    stats: CacheStats

func initCacheStore*[K, V](policy: CachePolicy): CacheStore[K, V] =
  ## Creates an empty store with revisions beginning at one.
  CacheStore[K, V](
    policy: policy,
    entries: initTable[K, StoredSnapshot[V]](),
    nextRevision: 1,
  )

func policy*[K, V](store: CacheStore[K, V]): CachePolicy {.raises: [].} =
  ## Returns the immutable policy selected when the store was created.
  store.policy

func stats*[K, V](store: CacheStore[K, V]): CacheStats {.raises: [].} =
  ## Returns a copy of cumulative counters.
  store.stats

func len*[K, V](store: CacheStore[K, V]): int {.inline.} =
  ## Returns stored entry count, including TTL entries not yet purged.
  store.entries.len

func isExpired[K, V](
    store: CacheStore[K, V];
    entry: StoredSnapshot[V];
    nowMs: int64,
): bool {.raises: [].} =
  store.policy.kind == cacheTtl and
    nowMs - entry.snapshot.observedAtMs >= store.policy.ttlMs

proc del*[K, V](store: var CacheStore[K, V]; key: K) =
  ## Deletes `key` without incrementing automatic-eviction counters.
  store.entries.del(key)

proc clear*[K, V](store: var CacheStore[K, V]) =
  ## Deletes all entries without resetting revisions or counters.
  store.entries.clear()

proc purgeExpired*[K, V](store: var CacheStore[K, V]; nowMs: int64): int =
  ## Removes all expired TTL entries and returns the removal count.
  if store.policy.kind != cacheTtl:
    return 0

  var expired: seq[K]
  for key, entry in store.entries.pairs:
    if store.isExpired(entry, nowMs):
      expired.add(key)
  for key in expired:
    store.entries.del(key)
  result = expired.len
  store.stats.evictions += uint64(result)

proc evictLeastRecentlyUsed[K, V](store: var CacheStore[K, V]): bool =
  # Access sequence, rather than wall-clock time, makes LRU ordering fully
  # deterministic even when several lookups share the same timestamp.
  var victim = none(K)
  var oldest = high(uint64)
  for key, entry in store.entries.pairs:
    if entry.lastAccess < oldest:
      oldest = entry.lastAccess
      victim = some(key)
  if victim.isSome:
    store.entries.del(victim.get)
    store.stats.evictions.inc
    true
  else:
    false

proc put*[K, V](
    store: var CacheStore[K, V];
    key: K;
    value: sink V;
    observedAtMs: int64,
): Option[Snapshot[V]] =
  ## Stores an immutable revision, evicting according to policy when needed.
  ##
  ## Disabled stores return `none` and do not advance their revision.
  if store.policy.kind == cacheDisabled:
    return none(Snapshot[V])

  discard store.purgeExpired(observedAtMs)
  if store.policy.kind in {cacheLru, cacheTtl} and
      not store.entries.hasKey(key) and
      store.entries.len >= store.policy.maxEntries:
    discard store.evictLeastRecentlyUsed()

  store.accessClock.inc
  let snapshot = initSnapshot(value, store.nextRevision, observedAtMs)
  store.nextRevision.inc
  store.entries[key] = StoredSnapshot[V](
    snapshot: snapshot,
    lastAccess: store.accessClock,
  )
  some(snapshot)

proc get*[K, V](
    store: var CacheStore[K, V];
    key: K;
    nowMs: int64,
): Option[Snapshot[V]] =
  ## Looks up `key`, updating LRU order and hit/miss counters.
  ##
  ## Expired TTL entries are removed before returning `none`.
  if not store.entries.hasKey(key):
    store.stats.misses.inc
    return none(Snapshot[V])

  var entry = store.entries.getOrDefault(key)
  if store.isExpired(entry, nowMs):
    store.entries.del(key)
    store.stats.misses.inc
    store.stats.evictions.inc
    return none(Snapshot[V])

  store.accessClock.inc
  entry.lastAccess = store.accessClock
  store.entries[key] = entry
  store.stats.hits.inc
  some(entry.snapshot)

func peek*[K, V](
    store: CacheStore[K, V];
    key: K;
    nowMs: int64,
): Option[Snapshot[V]] =
  ## Looks up a non-expired entry without changing LRU order or counters.
  if not store.entries.hasKey(key):
    return none(Snapshot[V])
  let entry = store.entries.getOrDefault(key)
  if store.isExpired(entry, nowMs):
    none(Snapshot[V])
  else:
    some(entry.snapshot)

func contains*[K, V](
    store: CacheStore[K, V];
    key: K;
    nowMs: int64,
): bool =
  ## Tests for a non-expired entry without changing store state.
  store.peek(key, nowMs).isSome

iterator pairs*[K, V](
    store: CacheStore[K, V];
    nowMs: int64,
): (K, Snapshot[V]) =
  ## Yields non-expired snapshots without purging or changing LRU order.
  for key, entry in store.entries.pairs:
    if not store.isExpired(entry, nowMs):
      yield (key, entry.snapshot)
