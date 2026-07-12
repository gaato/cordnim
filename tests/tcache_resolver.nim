import std/[options, unittest]

import chronos

import cordnim/cache/[policy, resolution]
import cordnim/cache/resolver

type FetchError = object of CatchableError

proc makeClock(nowMs: int64): MonotonicClock =
  var current = nowMs
  proc clockFn(): int64 {.gcsafe, raises: [].} =
    current
  clockFn

suite "EntityResolver":
  test "cacheOnly returns a hit without invoking the REST callback":
    proc scenario(): Future[tuple[
        fetchCalls: int, hasValue: bool, isFromCache: bool, value: string]]
        {.async.} =
      var fetchCalls = 0
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        inc fetchCalls
        let fut = newFuture[string]("test.fetch")
        fut.complete("rest-" & $key)
        fut
      let resolver = newEntityResolver[int, string](
        fullCache(), fetchFn, makeClock(1000))
      discard await resolver.fetch(7)
      let outcome = await resolver.resolve(7, cacheOnly)
      return (fetchCalls, outcome.isSome,
        outcome.isSome and outcome.get.source == resolvedFromCache,
        if outcome.isSome: outcome.get.value else: "")
    let r = waitFor scenario()
    check r.fetchCalls == 1
    check r.hasValue
    check r.isFromCache
    check r.value == "rest-7"

  test "cacheOnly reports a typed miss without invoking the REST callback":
    proc scenario(): Future[tuple[fetchCalls: int, isNone: bool]] {.async.} =
      var fetchCalls = 0
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        inc fetchCalls
        let fut = newFuture[string]("test.fetch")
        fut.complete("rest-" & $key)
        fut
      let resolver = newEntityResolver[int, string](
        fullCache(), fetchFn, makeClock(1000))
      let outcome = await resolver.resolve(1, cacheOnly)
      return (fetchCalls, outcome.isNone)
    let r = waitFor scenario()
    check r.fetchCalls == 0
    check r.isNone

  test "restOnly bypasses a cached value and always fetches":
    proc scenario(): Future[tuple[
        fetchCalls: int, isFromRest: bool, value: string]] {.async.} =
      var fetchCalls = 0
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        inc fetchCalls
        let fut = newFuture[string]("test.fetch")
        fut.complete("rest-" & $fetchCalls)
        fut
      let resolver = newEntityResolver[int, string](
        fullCache(), fetchFn, makeClock(1000))
      discard await resolver.fetch(1)
      let outcome = await resolver.resolve(1, restOnly)
      return (fetchCalls,
        outcome.isSome and outcome.get.source == resolvedFromRest,
        if outcome.isSome: outcome.get.value else: "")
    let r = waitFor scenario()
    check r.fetchCalls == 2
    check r.isFromRest
    check r.value == "rest-2"

  test "cacheThenRest uses a cache hit and skips the REST callback":
    proc scenario(): Future[tuple[fetchCalls: int, isFromCache: bool]]
        {.async.} =
      var fetchCalls = 0
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        inc fetchCalls
        let fut = newFuture[string]("test.fetch")
        fut.complete("rest-" & $key)
        fut
      let resolver = newEntityResolver[int, string](
        fullCache(), fetchFn, makeClock(1000))
      discard await resolver.fetch(3)
      let outcome = await resolver.resolve(3, cacheThenRest)
      return (fetchCalls,
        outcome.isSome and outcome.get.source == resolvedFromCache)
    let r = waitFor scenario()
    check r.fetchCalls == 1
    check r.isFromCache

  test "cacheThenRest fetches on a miss and populates the cache":
    proc scenario(): Future[tuple[
        fetchCalls: int, isFromRest: bool, value: string,
        cachedAfterwards: bool, fetchCallsAfterwards: int]] {.async.} =
      var fetchCalls = 0
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        inc fetchCalls
        let fut = newFuture[string]("test.fetch")
        fut.complete("rest-" & $key)
        fut
      let resolver = newEntityResolver[int, string](
        fullCache(), fetchFn, makeClock(1000))
      let outcome = await resolver.resolve(5, cacheThenRest)
      # The populated entry must now be visible to a cache-only lookup,
      # without a second REST call.
      let cachedOutcome = resolver.cached(5)
      return (fetchCalls,
        outcome.isSome and outcome.get.source == resolvedFromRest,
        if outcome.isSome: outcome.get.value else: "",
        cachedOutcome.isSome and cachedOutcome.get.source == resolvedFromCache,
        fetchCalls)
    let r = waitFor scenario()
    check r.fetchCalls == 1
    check r.isFromRest
    check r.value == "rest-5"
    check r.cachedAfterwards
    check r.fetchCallsAfterwards == 1

  test "exposes cache state and supports explicit invalidation":
    proc scenario(): Future[tuple[
        policyIsFull: bool; before, afterOne, afterAll: int;
        hits, misses: uint64]] {.async.} =
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        let fut = newFuture[string]("test.fetch")
        fut.complete("rest-" & $key)
        fut
      let resolver = newEntityResolver[int, string](
        fullCache(), fetchFn, makeClock(1000))
      let policyIsFull = resolver.policy.kind == cacheFull
      discard await resolver.fetch(1)
      discard await resolver.fetch(2)
      discard resolver.cached(1)
      discard resolver.cached(9)
      let before = resolver.len
      resolver.invalidate(1)
      let afterOne = resolver.len
      resolver.clear()
      let state = resolver.stats
      return (policyIsFull, before, afterOne, resolver.len,
        state.hits, state.misses)
    let r = waitFor scenario()
    check r.policyIsFull
    check r.before == 2
    check r.afterOne == 1
    check r.afterAll == 0
    check r.hits == 1
    check r.misses == 1

  test "fetch does not populate a disabled cache":
    proc scenario(): Future[tuple[
        isFromRest: bool, value: string, cachedAfterwards: bool]] {.async.} =
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        let fut = newFuture[string]("test.fetch")
        fut.complete("rest-" & $key)
        fut
      let resolver = newEntityResolver[int, string](
        disabledCache(), fetchFn, makeClock(1000))
      let resolved = await resolver.fetch(9)
      return (resolved.source == resolvedFromRest, resolved.value,
        resolver.cached(9).isSome)
    let r = waitFor scenario()
    check r.isFromRest
    check r.value == "rest-9"
    check not r.cachedAfterwards

  test "fetch failure propagates instead of becoming a miss":
    proc scenario(): Future[tuple[failed: bool, stillUncached: bool]]
        {.async.} =
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        let fut = newFuture[string]("test.fetch")
        fut.fail(newException(FetchError, "discord rest failed"))
        fut
      let resolver = newEntityResolver[int, string](
        fullCache(), fetchFn, makeClock(1000))
      var failed = false
      try:
        discard await resolver.resolve(2, restOnly)
      except FetchError:
        failed = true
      return (failed, resolver.cached(2).isNone)
    let r = waitFor scenario()
    check r.failed
    check r.stillUncached

  test "caller cancellation of fetch propagates instead of becoming a miss":
    proc scenario(): Future[tuple[pendingCancelled, heldCancelled: bool]]
        {.async.} =
      let held = newFuture[string]("test.held")
      proc fetchFn(key: int): Future[string] {.gcsafe, raises: [].} =
        held
      let resolver = newEntityResolver[int, string](
        fullCache(), fetchFn, makeClock(1000))
      let pending = resolver.fetch(4)
      await sleepAsync(1.milliseconds)
      await pending.cancelAndWait()
      return (pending.cancelled(), held.cancelled())
    let r = waitFor scenario()
    check r.pendingCancelled
    check r.heldCancelled
