## Declarative cache retention policies with no implicit REST behavior.

type
  CachePolicyKind* = enum ## Storage and eviction strategy for one cache domain.
    cacheDisabled, ## Do not retain entries.
    cacheFull,     ## Retain entries until explicit deletion or clear.
    cacheLru,      ## Enforce a count limit with least-recently-used eviction.
    cacheTtl       ## Enforce both an age limit and a count limit.

  PositiveMillis* = range[1'i64 .. high(int64)] ## Positive millisecond duration accepted by cache policies.

  CachePolicy* = object ## Validated retention settings for one cache store.
    kind*: CachePolicyKind ## Storage and eviction strategy.
    maxEntries*: int ## Count limit for LRU and TTL policies; zero otherwise.
    ttlMs*: int64 ## Maximum age for TTL entries; zero otherwise.

  CachePolicies* = object ## Independent retention settings for common Gateway entities.
    guilds*: CachePolicy ## Guild snapshot retention.
    channels*: CachePolicy ## Channel and thread snapshot retention.
    members*: CachePolicy ## Guild-member snapshot retention.
    messages*: CachePolicy ## Message snapshot retention.
    presences*: CachePolicy ## Presence snapshot retention.

func disabledCache*(): CachePolicy {.raises: [].} =
  ## Creates a policy that rejects all inserted entries.
  CachePolicy(kind: cacheDisabled)

func fullCache*(): CachePolicy {.raises: [].} =
  ## Creates an unbounded policy requiring explicit eviction.
  CachePolicy(kind: cacheFull)

func lruCache*(maxEntries: Positive): CachePolicy {.raises: [].} =
  ## Creates a count-bounded least-recently-used policy.
  CachePolicy(kind: cacheLru, maxEntries: int(maxEntries))

func ttlCache*(
    ttlMs: PositiveMillis;
    maxEntries: Positive,
): CachePolicy {.raises: [].} =
  ## Creates an age- and count-bounded policy.
  CachePolicy(
    kind: cacheTtl,
    maxEntries: int(maxEntries),
    ttlMs: int64(ttlMs),
  )

func minimalCachePolicies*(): CachePolicies {.raises: [].} =
  ## Retains guilds and channels while disabling higher-volume domains.
  CachePolicies(
    guilds: fullCache(),
    channels: fullCache(),
    members: disabledCache(),
    messages: disabledCache(),
    presences: disabledCache(),
  )
