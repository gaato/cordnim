## Resolution policy is explicit so a cache lookup can never hide network I/O.

type
  ResolvePolicy* = enum ## Explicit sources allowed for an entity lookup.
    cacheOnly, ## Consult local cache only and never perform network I/O.
    restOnly, ## Bypass cache and fetch from Discord REST.
    cacheThenRest ## Use cache when present, otherwise fetch from REST.

  ResolveSource* = enum ## Source that produced a successfully resolved entity.
    resolvedFromCache, ## Value came from local snapshot storage.
    resolvedFromRest ## Value came from an explicit Discord REST request.

  Resolved*[T] = object ## Resolved value carrying its observable source.
    value*: T ## Resolved entity or snapshot.
    source*: ResolveSource ## Cache or REST source used to obtain `value`.

func fromCache*[T](value: sink T): Resolved[T] =
  ## Wraps a successful cache resolution.
  Resolved[T](value: value, source: resolvedFromCache)

func fromRest*[T](value: sink T): Resolved[T] =
  ## Wraps a successful REST resolution.
  Resolved[T](value: value, source: resolvedFromRest)
