## Deterministic ORC tests for the Gateway coordination contract and its local
## adapter.
##
## Every time value comes from one injected clock reference the test advances by
## hand, so lease expiry, fencing takeover, and IDENTIFY bucket spacing are fully
## deterministic without sleeping.

import std/[options, strutils]

import chronos

import cordnim/gateway/[coordination, identify, session]
import cordnim/core/secrets

proc makeClock(startMs: int64): (WallClock, ref int64) =
  ## Returns a wall clock over a fresh, proc-local time cell plus that cell, so
  ## the closure stays GC-safe while the test advances time by hand.
  let clk = new(int64)
  clk[] = startMs
  let clock: WallClock = proc(): int64 {.gcsafe, raises: [].} = clk[]
  (clock, clk)

proc freshLocal(
    startMs: int64;
    ttlMs: int64;
    limit: SessionStartLimit,
): (LocalGatewayCoordination, ref int64) =
  ## Builds a local adapter over a hand-advanced clock and returns both so a test
  ## can move backend time forward deterministically.
  let (clock, clk) = makeClock(startMs)
  (newLocalGatewayCoordination(clock, ttlMs, limit), clk)

proc defaultLimit(
    total = 5;
    remaining = 5;
    resetAfterMs = 10_000'i64;
    maxConcurrency = 2'u16,
): SessionStartLimit =
  SessionStartLimit(
    total: total,
    remaining: remaining,
    resetAfterMs: resetAfterMs,
    maxConcurrency: maxConcurrency,
  )

proc readyState(sessionId, url: string; sequence: int64): GatewaySessionState =
  result = initGatewaySession(ShardId(0))
  result.recordReady(sessionId, url)
  discard result.observeSequence(GatewaySequence(sequence))

proc stubRenew(lease: ShardLease): LeaseRenewFuture {.gcsafe, raises: [].} =
  result = LeaseRenewFuture.init("stub.renew")
  result.complete(LeaseRenewResult(status: leaseLost))

proc stubRelease(lease: ShardLease): LeaseReleaseFuture {.gcsafe, raises: [].} =
  result = LeaseReleaseFuture.init("stub.release")
  result.complete(leaseReleaseRejected)

proc stubReserve(shardId: ShardId): IdentifyReservationFuture {.
    gcsafe, raises: [].} =
  result = IdentifyReservationFuture.init("stub.reserve")
  result.complete(IdentifyReservation(
    maxConcurrency: 1, remaining: 0, resetAfterMs: 0,
    status: identifyDeferred, retryAfterMs: 0))

proc stubWrite(
    lease: ShardLease; state: GatewaySessionState): SessionWriteFuture {.
    gcsafe, raises: [].} =
  result = SessionWriteFuture.init("stub.write")
  result.complete(sessionWriteRejected)

proc stubRead(lease: ShardLease): SessionReadFuture {.gcsafe, raises: [].} =
  result = SessionReadFuture.init("stub.read")
  result.complete(SessionReadResult(status: sessionReadRejected))

proc suspendingContract(): GatewayCoordination =
  ## A contract whose `acquireShard` never completes on its own, built inside a
  ## proc so the captured pending future is GC-safe rather than a global.
  let pending = ShardAcquireFuture.init("test.pending-acquire")
  newGatewayCoordination(
    acquireShardProc = proc(shardId: ShardId): ShardAcquireFuture {.
        gcsafe, raises: [].} = pending,
    renewShardProc = stubRenew,
    releaseShardProc = stubRelease,
    reserveIdentifyProc = stubReserve,
    writeSessionProc = stubWrite,
    readSessionProc = stubRead,
  )

proc failingAcquireContract(kind: CoordinationErrorKind): GatewayCoordination =
  ## A contract whose `acquireShard` fails with a typed backend error, proving the
  ## facade futures allow `GatewayCoordinationError` and carry its stable kind.
  newGatewayCoordination(
    acquireShardProc = proc(shardId: ShardId): Future[ShardAcquireResult] {.
        gcsafe, async: (raises: [CancelledError, GatewayCoordinationError]).} =
      raise newGatewayCoordinationError(kind, "backend-secret-detail"),
    renewShardProc = stubRenew,
    releaseShardProc = stubRelease,
    reserveIdentifyProc = stubReserve,
    writeSessionProc = stubWrite,
    readSessionProc = stubRead,
  )

block exclusive_shard_lease:
  let (local, _) = freshLocal(1_000, 10_000, defaultLimit())
  let a = waitFor local.acquireShard(ShardId(0))
  doAssert a.status == shardAcquired
  doAssert a.lease.shardId == ShardId(0)
  doAssert a.lease.token.toUint64 == 1'u64
  # The lease carries a relative TTL, never an absolute backend clock value.
  doAssert a.lease.ttlMs == 10_000
  # A second acquire is refused while the shard is held, with a relative wait.
  let b = waitFor local.acquireShard(ShardId(0))
  doAssert b.status == shardHeld
  doAssert b.retryAfterMs == 10_000

block lease_renewal_extends_expiry_with_same_token:
  let (local, clk) = freshLocal(1_000, 10_000, defaultLimit())
  let a = waitFor local.acquireShard(ShardId(0))
  clk[] += 3_000
  let r = waitFor local.renewShard(a.lease)
  doAssert r.status == leaseRenewed
  doAssert r.lease.token == a.lease.token
  doAssert r.lease.ttlMs == 10_000
  # The renewed lease outlives the original: at +9s from the renew it still holds.
  clk[] += 9_000
  doAssert (waitFor local.renewShard(a.lease)).status == leaseRenewed

block expired_lease_is_taken_over_with_higher_fence:
  let (local, clk) = freshLocal(1_000, 10_000, defaultLimit())
  let a = waitFor local.acquireShard(ShardId(0))
  clk[] += 10_001 # past the lease expiry
  let b = waitFor local.acquireShard(ShardId(0))
  doAssert b.status == shardAcquired
  doAssert b.lease.token.toUint64 == 2'u64
  doAssert a.lease.token < b.lease.token # fencing token strictly increases

  # The superseded owner can neither renew nor release the new lease.
  doAssert (waitFor local.renewShard(a.lease)).status == leaseLost
  doAssert (waitFor local.releaseShard(a.lease)) == leaseReleaseRejected
  # The current owner still controls its lease.
  doAssert (waitFor local.renewShard(b.lease)).status == leaseRenewed

block stale_release_leaves_the_current_lease_intact:
  let (local, clk) = freshLocal(1_000, 10_000, defaultLimit())
  let a = waitFor local.acquireShard(ShardId(0))
  clk[] += 10_001
  let b = waitFor local.acquireShard(ShardId(0))
  doAssert b.status == shardAcquired
  # A stale release must not clear the current owner's lease.
  doAssert (waitFor local.releaseShard(a.lease)) == leaseReleaseRejected
  doAssert (waitFor local.renewShard(b.lease)).status == leaseRenewed
  # The rightful owner can release, and the shard becomes acquirable again.
  doAssert (waitFor local.releaseShard(b.lease)) == leaseReleased
  let c = waitFor local.acquireShard(ShardId(0))
  doAssert c.status == shardAcquired
  doAssert b.lease.token < c.lease.token

block session_write_and_read_are_fenced:
  let (local, clk) = freshLocal(1_000, 10_000, defaultLimit())
  let a = waitFor local.acquireShard(ShardId(0))
  doAssert (waitFor local.writeSession(
    a.lease, readyState("sess-1", "wss://resume-1", 42))) == sessionWritten
  let stored = waitFor local.readSession(a.lease)
  doAssert stored.status == sessionRead
  doAssert stored.state.isSome
  doAssert stored.state.get.sessionId == "sess-1"
  doAssert stored.state.get.sequence.get.toInt64 == 42

  # Take the lease over, then prove a stale owner can neither overwrite nor read
  # the new owner's resume state.
  clk[] += 10_001
  let b = waitFor local.acquireShard(ShardId(0))
  doAssert (waitFor local.writeSession(
    a.lease, readyState("stale", "wss://stale", 99))) == sessionWriteRejected
  doAssert (waitFor local.readSession(a.lease)).status == sessionReadRejected
  let afterStale = waitFor local.readSession(b.lease)
  doAssert afterStale.status == sessionRead
  doAssert afterStale.state.get.sessionId == "sess-1"

  # The new owner writes and reads successfully.
  doAssert (waitFor local.writeSession(
    b.lease, readyState("sess-2", "wss://resume-2", 100))) == sessionWritten
  let afterFresh = waitFor local.readSession(b.lease)
  doAssert afterFresh.status == sessionRead
  doAssert afterFresh.state.get.sessionId == "sess-2"
  doAssert afterFresh.state.get.sequence.get.toInt64 == 100

block identify_buckets_are_independent_and_spaced:
  let (local, clk) = freshLocal(
    1_000, 10_000, defaultLimit(total = 5, remaining = 5, maxConcurrency = 2))
  let r0 = waitFor local.reserveIdentify(ShardId(0)) # bucket 0
  doAssert r0.status == identifyReserved
  doAssert r0.lease.bucket == 0'u16
  doAssert r0.maxConcurrency == 2'u16
  doAssert r0.remaining == 4
  doAssert r0.resetAfterMs == 10_000 # relative duration until the budget resets

  # Bucket 1 is independent of bucket 0 and is not blocked by it.
  let r1 = waitFor local.reserveIdentify(ShardId(1)) # bucket 1
  doAssert r1.status == identifyReserved
  doAssert r1.lease.bucket == 1'u16
  doAssert r1.remaining == 3

  # Shard 2 shares bucket 0 and must wait five seconds for it.
  let deferred = waitFor local.reserveIdentify(ShardId(2))
  doAssert deferred.status == identifyDeferred
  doAssert deferred.retryAfterMs == 5_000 # relative wait, not an absolute time
  doAssert deferred.remaining == 3 # a deferred reservation consumes nothing

  clk[] += 5_000
  let r2 = waitFor local.reserveIdentify(ShardId(2))
  doAssert r2.status == identifyReserved
  doAssert r2.lease.bucket == 0'u16
  doAssert r2.remaining == 2

block identify_budget_resets_after_its_window:
  let (local, clk) = freshLocal(
    1_000, 10_000, defaultLimit(total = 1, remaining = 1, maxConcurrency = 1))
  let r0 = waitFor local.reserveIdentify(ShardId(0))
  doAssert r0.status == identifyReserved
  doAssert r0.remaining == 0

  # Budget is exhausted; the retry hint is the wait until reset, not the bucket.
  clk[] += 5_000
  let exhausted = waitFor local.reserveIdentify(ShardId(0))
  doAssert exhausted.status == identifyDeferred
  doAssert exhausted.retryAfterMs == 5_000 # now 6_000, budget resets at 11_000
  doAssert exhausted.remaining == 0 # never refunded

  # After the reset window the budget is replenished.
  clk[] += 5_001
  let replenished = waitFor local.reserveIdentify(ShardId(0))
  doAssert replenished.status == identifyReserved
  doAssert replenished.remaining == 0
  doAssert replenished.resetAfterMs == 10_000 # a fresh full window ahead

block construction_validates_ttl_clock_and_identify_limits:
  let (clock, _) = makeClock(0)
  doAssertRaises ValueError:
    discard newLocalGatewayCoordination(clock, 0, defaultLimit())
  doAssertRaises ValueError:
    discard newLocalGatewayCoordination(nil, 10_000, defaultLimit())
  doAssertRaises ValueError:
    discard newLocalGatewayCoordination(
      clock, 10_000, defaultLimit(maxConcurrency = 0))

block facade_forwards_every_method_to_the_local_adapter:
  let (local, _) = freshLocal(1_000, 10_000, defaultLimit())
  let contract = local.asCoordination()
  let a = waitFor contract.acquireShard(ShardId(0))
  doAssert a.status == shardAcquired
  doAssert (waitFor contract.acquireShard(ShardId(0))).status == shardHeld
  doAssert (waitFor contract.writeSession(
    a.lease, readyState("s", "wss://u", 7))) == sessionWritten
  let stored = waitFor contract.readSession(a.lease)
  doAssert stored.status == sessionRead
  doAssert stored.state.isSome and stored.state.get.sessionId == "s"
  doAssert (waitFor contract.reserveIdentify(ShardId(0))).status ==
    identifyReserved
  doAssert (waitFor contract.renewShard(a.lease)).status == leaseRenewed
  doAssert (waitFor contract.releaseShard(a.lease)) == leaseReleased

block contract_forwards_and_stays_cancellation_transparent:
  let contract = suspendingContract()
  let fut = contract.acquireShard(ShardId(0))
  doAssert not fut.finished
  fut.cancelSoon()
  doAssertRaises CancelledError:
    discard waitFor fut

block contract_rejects_nil_callbacks:
  doAssertRaises ValueError:
    discard newGatewayCoordination(
      nil, stubRenew, stubRelease, stubReserve, stubWrite, stubRead)

block diagnostics_expose_no_secret_fields:
  let (local, _) = freshLocal(1_000, 10_000, defaultLimit())
  let a = waitFor local.acquireShard(ShardId(3))
  let leaseText = $a.lease
  doAssert leaseText.find(redactedSecret) == -1
  doAssert leaseText.find("token: 1") != -1 # the fencing token is diagnostic
  let r = waitFor local.reserveIdentify(ShardId(3))
  doAssert ($r).find(redactedSecret) == -1

block lease_ttl_addition_saturates_instead_of_wrapping:
  # A pathologically large TTL must clamp the expiry to int64.high, not wrap it
  # negative. Wrapping would make the fresh lease look already expired, letting a
  # second acquire steal an owned shard, which would violate fencing.
  let (local, _) = freshLocal(1_000, high(int64), defaultLimit())
  let a = waitFor local.acquireShard(ShardId(0))
  doAssert a.status == shardAcquired
  doAssert a.lease.ttlMs == high(int64)
  let b = waitFor local.acquireShard(ShardId(0))
  doAssert b.status == shardHeld # still held, never silently freed
  doAssert b.retryAfterMs >= 0 # clamped, never negative from a wrap
  doAssert (waitFor local.renewShard(a.lease)).status == leaseRenewed

block coordination_error_carries_stable_kind_and_hides_detail:
  let err = newGatewayCoordinationError(ceConflict, "redis MOVED 1234 leaked-secret")
  doAssert err.kind == ceConflict
  doAssert err.kind.code == 2'u16
  doAssert err.kind.name == "conflict"
  # Every kind maps to a distinct, stable code.
  var codes: seq[uint16]
  for k in CoordinationErrorKind:
    codes.add k.code
  doAssert codes == @[1'u16, 2, 3, 4, 5]
  # The diagnostic renders the stable kind and code but never the adapter message.
  let text = err.diagnostic
  doAssert text.find("conflict") != -1
  doAssert text.find("leaked-secret") == -1
  doAssert err.msg.find("leaked-secret") != -1 # detail is retained but not shown

block contract_futures_surface_typed_backend_failure:
  let failing = failingAcquireContract(ceUnavailable)
  let fut = failing.acquireShard(ShardId(0))
  try:
    discard waitFor fut
    doAssert false, "expected a typed coordination failure"
  except GatewayCoordinationError as err:
    doAssert err.kind == ceUnavailable
    doAssert err.diagnostic.find("backend-secret-detail") == -1

echo "tgateway_coordination: all blocks passed"
