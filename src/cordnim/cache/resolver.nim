## Cache-first entity resolution over an injected asynchronous REST fetch.
##
## `EntityResolver` composes a `CacheStore` with a caller-supplied REST fetch
## callback and monotonic clock so lookup policy stays explicit: `cached`
## never performs network I/O, `fetch` always performs it, and `resolve`
## dispatches between them by `ResolvePolicy`. One Chronos event-loop owner
## drives a resolver; it is not synchronized for cross-thread access.

import std/options

import chronos

import ./[policy, resolution, snapshots, store]

type
  MonotonicClock* = proc(): int64 {.gcsafe, raises: [].}
    ## Injected monotonic millisecond clock. Callers must keep it
    ## non-decreasing; the resolver never reads wall-clock time itself.

  EntityFetch*[K, V] = proc(key: K): Future[V] {.gcsafe, raises: [].}
    ## Injected asynchronous Discord REST fetch for one entity key.
    ##
    ## The returned future may fail with `CancelledError` or any other
    ## `CatchableError` (typically a `DiscordError`); `fetch` and `resolve`
    ## propagate either unchanged rather than reporting a cache miss.

  EntityResolver*[K, V] = ref object ## Cache-first lookup for one entity
    ## domain, bound to one Chronos event loop.
    store: CacheStore[K, V]
    fetchFn: EntityFetch[K, V]
    clock: MonotonicClock

func policy*[K, V](resolver: EntityResolver[K, V]): CachePolicy
    {.raises: [].} =
  ## Returns the immutable retention policy used by the resolver's store.
  resolver.store.policy

func stats*[K, V](resolver: EntityResolver[K, V]): CacheStats
    {.raises: [].} =
  ## Returns a copy of cumulative cache lookup and eviction counters.
  resolver.store.stats

func len*[K, V](resolver: EntityResolver[K, V]): int {.raises: [].} =
  ## Returns the number of retained entries, including unpurged TTL entries.
  resolver.store.len

proc newEntityResolver*[K, V](
    cachePolicy: CachePolicy;
    fetchFn: EntityFetch[K, V];
    clock: MonotonicClock,
): EntityResolver[K, V] =
  ## Creates a resolver over a fresh cache store governed by `cachePolicy`.
  if fetchFn.isNil:
    raise newException(ValueError,
      "entity resolver fetch callback must not be nil")
  if clock.isNil:
    raise newException(ValueError, "entity resolver clock must not be nil")
  EntityResolver[K, V](
    store: initCacheStore[K, V](cachePolicy),
    fetchFn: fetchFn,
    clock: clock,
  )

proc cached*[K, V](
    resolver: EntityResolver[K, V];
    key: K,
): Option[Resolved[V]] =
  ## Consults the local cache for `key` only; never performs REST I/O.
  let snapshot = resolver.store.get(key, resolver.clock())
  if snapshot.isSome:
    some(fromCache(snapshot.get.value))
  else:
    none(Resolved[V])

proc invalidate*[K, V](resolver: EntityResolver[K, V]; key: K) =
  ## Removes one cached entity without performing REST I/O.
  ##
  ## Gateway delete/update handlers use this explicit operation to prevent a
  ## subsequent `cacheThenRest` lookup from returning a known-stale snapshot.
  resolver.store.del(key)

proc clear*[K, V](resolver: EntityResolver[K, V]) =
  ## Removes every retained entity without changing policy or cumulative stats.
  resolver.store.clear()

proc fetch*[K, V](
    resolver: EntityResolver[K, V];
    key: K,
): Future[Resolved[V]] {.async.} =
  ## Always performs REST I/O for `key`, bypassing any cache lookup.
  ##
  ## Populates the cache with the fetched value when its policy is enabled.
  ## Fetch failure and caller cancellation propagate unchanged; neither is
  ## folded into a cache miss.
  let value = await resolver.fetchFn(key)
  if resolver.store.policy.kind == cacheDisabled:
    return fromRest(value)
  let stored = resolver.store.put(key, value, resolver.clock())
  # `put` only returns `none` for a disabled policy, already excluded above.
  fromRest(stored.get.value)

proc resolve*[K, V](
    resolver: EntityResolver[K, V];
    key: K;
    resolvePolicy: ResolvePolicy,
): Future[Option[Resolved[V]]] {.async.} =
  ## Resolves `key` according to the explicit `resolvePolicy`.
  ##
  ## `cacheOnly` never performs REST I/O and returns `none` on a cache miss.
  ## `restOnly` always performs REST I/O, bypassing the cache lookup.
  ## `cacheThenRest` uses a cache hit when present and otherwise fetches.
  case resolvePolicy
  of cacheOnly:
    resolver.cached(key)
  of restOnly:
    some(await resolver.fetch(key))
  of cacheThenRest:
    let hit = resolver.cached(key)
    if hit.isSome:
      hit
    else:
      some(await resolver.fetch(key))
