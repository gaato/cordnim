## Opt-in, process-local caches for immutable entity snapshots.
##
## `CacheStore` applies a disabled, full, LRU, or TTL policy without starting
## network work. `EntityResolver` performs a fetch only when its
## `ResolvePolicy` permits REST access, and reports whether a result came from
## cache or REST. Callers supply the fetch callback and monotonic clock. One
## Chronos event loop owns each mutable store or resolver.

import cordnim/cache/all

export all

runnableExamples:
  var store = initCacheStore[int, string](lruCache(2))
  discard store.put(1, "one", observedAtMs = 10)
  discard store.put(2, "two", observedAtMs = 10)
  doAssert store.contains(1, nowMs = 10)

  discard store.put(3, "three", observedAtMs = 11)
  doAssert not store.contains(1, nowMs = 11)
  doAssert store.contains(3, nowMs = 11)
