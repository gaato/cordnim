import std/[options, unittest]

import chronos

import cordnim/collectors

suite "Collector":
  test "offer admits items in order and next drains them":
    proc scenario(): Future[tuple[
        firstOffer, secondOffer: CollectorOfferResult;
        first, second: int]] {.async.} =
      let collector = newCollector[int](4)
      let firstOffer = collector.offer(1)
      let secondOffer = collector.offer(2)
      let first = await collector.next()
      let second = await collector.next()
      return (firstOffer, secondOffer, first.get, second.get)
    let r = waitFor scenario()
    check r.firstOffer == offerAccepted
    check r.secondOffer == offerAccepted
    check r.first == 1
    check r.second == 2

  test "predicate rejects non-matching items without queuing them":
    proc scenario(): Future[tuple[
        rejected: CollectorOfferResult, accepted: CollectorOfferResult,
        len: int]] {.async.} =
      proc onlyEven(item: int): bool {.gcsafe, raises: [].} =
        item mod 2 == 0
      let collector = newCollector[int](4, onlyEven)
      let rejected = collector.offer(3)
      let accepted = collector.offer(4)
      return (rejected, accepted, collector.len)
    let r = waitFor scenario()
    check r.rejected == offerRejectedByFilter
    check r.accepted == offerAccepted
    check r.len == 1

  test "capacity overflow is rejected without growing the queue":
    proc scenario(): Future[tuple[
        results: seq[CollectorOfferResult], len, capacity: int]] {.async.} =
      let collector = newCollector[int](2)
      var results: seq[CollectorOfferResult]
      results.add collector.offer(1)
      results.add collector.offer(2)
      results.add collector.offer(3)
      return (results, collector.len, collector.capacity)
    let r = waitFor scenario()
    check r.results == @[offerAccepted, offerAccepted, offerRejectedFull]
    check r.len == 2
    check r.capacity == 2

  test "next returns none after its timeout elapses":
    proc scenario(): Future[tuple[isNone: bool, stillEmpty: bool]] {.async.} =
      let collector = newCollector[int](2)
      let value = await collector.next(timeout = 5.milliseconds)
      return (value.isNone, collector.len == 0)
    let r = waitFor scenario()
    check r.isNone
    check r.stillEmpty

  test "stop wakes a pending next() call with none":
    proc scenario(): Future[tuple[isNone: bool, stoppedAfter: bool]]
        {.async.} =
      let collector = newCollector[int](2)
      let pending = collector.next()
      await sleepAsync(1.milliseconds)
      await collector.stop()
      let value = await pending
      return (value.isNone, collector.isStopped)
    let r = waitFor scenario()
    check r.isNone
    check r.stoppedAfter

  test "stop is idempotent":
    proc scenario(): Future[bool] {.async.} =
      let collector = newCollector[int](2)
      await collector.stop()
      await collector.stop()
      return collector.isStopped
    check waitFor scenario()

  test "stop discards undelivered items and rejects new offers":
    proc scenario(): Future[tuple[
        firstOffer: CollectorOfferResult,
        offerAfterStop: CollectorOfferResult, len: int, nextAfterStop: bool]]
        {.async.} =
      let collector = newCollector[int](4)
      let firstOffer = collector.offer(1)
      await collector.stop()
      let offerAfterStop = collector.offer(2)
      let nextAfterStop = await collector.next()
      return (firstOffer, offerAfterStop, collector.len, nextAfterStop.isNone)
    let r = waitFor scenario()
    check r.firstOffer == offerAccepted
    check r.offerAfterStop == offerRejectedStopped
    check r.len == 0
    check r.nextAfterStop

  test "caller cancellation of next propagates instead of becoming none":
    proc scenario(): Future[bool] {.async.} =
      let collector = newCollector[int](2)
      let pending = collector.next()
      await sleepAsync(1.milliseconds)
      await pending.cancelAndWait()
      return pending.cancelled()
    check waitFor scenario()

  test "no future is retained once stop settles a pending waiter":
    proc scenario(): Future[tuple[
        pendingFinished: bool, secondCallResolvesImmediately: bool]]
        {.async.} =
      let collector = newCollector[int](2)
      let pending = collector.next()
      await collector.stop()
      # `stop` must not return until every future it owned has settled.
      let pendingFinished = pending.finished()
      let secondResult = await collector.next()
      return (pendingFinished, secondResult.isNone)
    let r = waitFor scenario()
    check r.pendingFinished
    check r.secondCallResolvesImmediately
