import std/[assertions, options]

import cordnim/cache/[policy, snapshots, store]

block disabled_cache_rejects_values:
  var cache = initCacheStore[string, string](disabledCache())
  doAssert cache.put("a", "ignored", 0).isNone
  doAssert cache.len == 0

block lru_cache_is_bounded:
  var cache = initCacheStore[string, string](lruCache(2))
  let first = cache.put("a", "alpha", 100).get
  doAssert first.revision == 1
  doAssert first.value == "alpha"
  discard cache.put("b", "beta", 100)
  doAssert cache.get("a", 101).isSome
  discard cache.put("c", "gamma", 102)
  doAssert cache.contains("a", 102)
  doAssert not cache.contains("b", 102)
  doAssert cache.contains("c", 102)
  doAssert cache.stats.evictions == 1

block ttl_cache_uses_explicit_clock:
  var cache = initCacheStore[int, string](ttlCache(10, 3))
  discard cache.put(1, "one", 100)
  doAssert cache.peek(1, 109).isSome
  doAssert cache.get(1, 110).isNone
  doAssert cache.stats.misses == 1
  doAssert cache.stats.evictions == 1

block snapshots_are_revisioned:
  var cache = initCacheStore[int, string](fullCache())
  let older = cache.put(1, "old", 10).get
  let newer = cache.put(1, "new", 20).get
  doAssert newer.isNewerThan(older.revision)
  doAssert cache.get(1, 20).get.value == "new"
