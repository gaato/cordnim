## Backend-neutral coordination for Gateway shards.
##
## `GatewayCoordination` groups shard leases, fenced session persistence, and
## IDENTIFY reservations behind injectable asynchronous operations. Lease-bound
## reads, writes, renewals, and releases present the same fencing token, so a
## superseded process cannot resume or overwrite the current owner's session.
## Timing results are relative durations rather than backend timestamps, and a
## granted IDENTIFY permit is never refunded.
##
## `LocalGatewayCoordination` implements the contract for one event loop. It is
## useful for tests and single-process applications, but it does not coordinate
## separate hosts. Production adapters must provide atomic lease and fencing
## operations using their backend's clock.

import std/[options, tables]

import chronos

import ./[identify, session]

type
  CoordinationErrorKind* = enum ## Stable, adapter-neutral coordination failure
    ## category. The set is closed and versioned so logs, metrics, and retry
    ## policy can branch on it without parsing backend prose.
    ceUnavailable, ## The backend was unreachable, timed out, or lost quorum.
    ceConflict, ## A conditional operation lost a race at the backend.
    ceProtocol, ## The backend returned an unexpected or malformed reply.
    ceDenied, ## The backend refused the operation (authentication/permission).
    ceInternal ## The backend reported an internal error.

  GatewayCoordinationError* = object of CatchableError ## Typed coordination
    ## backend failure raised through the contract futures.
    ##
    ## `kind` and its derived `code` are stable across adapters and safe to log or
    ## export. The inherited `msg` may carry adapter-specific detail (a Redis
    ## reply, an etcd status) and must be treated as potentially sensitive: render
    ## `diagnostic` for operator-visible output rather than the raw message.
    kind*: CoordinationErrorKind ## Stable failure category.

  FencingToken* = distinct uint64 ## Opaque, monotonically increasing lease epoch.
    ## Higher values supersede lower ones; the concrete value is backend-defined.

  ShardLease* = object ## Proof of current ownership of one shard's session.
    shardId*: ShardId ## Shard the lease governs.
    token*: FencingToken ## Fencing token identifying this ownership epoch.
    ttlMs*: int64 ## Remaining lifetime of the lease in milliseconds, measured
      ## from when this result is observed. A relative duration, not an absolute
      ## backend clock, so the owner records a conservative local expiry
      ## (`own clock + ttlMs`) and must renew before it elapses. Otherwise it must
      ## stop dispatching. Backends must return a positive value; a non-positive TTL cannot
      ## bound ownership and is rejected by the runner.

  ShardAcquireStatus* = enum ## Outcome kind of `acquireShard`.
    shardAcquired, ## A lease was granted with a fresh fencing token.
    shardHeld ## Another owner currently holds the shard.

  ShardAcquireResult* = object ## Lease or retry hint from `acquireShard`.
    case status*: ShardAcquireStatus
    of shardAcquired:
      lease*: ShardLease ## Granted lease.
    of shardHeld:
      retryAfterMs*: int64 ## Nonnegative milliseconds to wait before the shard
        ## may be retried; the current lease expires no sooner than this.

  LeaseRenewStatus* = enum ## Outcome kind of `renewShard`.
    leaseRenewed, ## Expiry was extended; the fencing token is unchanged.
    leaseLost ## The token was stale or the lease had already lapsed.

  LeaseRenewResult* = object ## Extended lease or loss signal from `renewShard`.
    case status*: LeaseRenewStatus
    of leaseRenewed:
      lease*: ShardLease ## Same-token lease with a later expiry.
    of leaseLost:
      discard

  LeaseReleaseStatus* = enum ## Outcome of `releaseShard`.
    leaseReleased, ## The caller's lease was cleared.
    leaseReleaseRejected ## The token was stale; the current lease was untouched.

  SessionWriteStatus* = enum ## Outcome of a conditional session write.
    sessionWritten, ## Resume state was stored under the caller's valid lease.
    sessionWriteRejected ## The token was stale; no state was written.

  SessionReadStatus* = enum ## Outcome kind of a fenced `readSession`.
    sessionRead, ## The lease was current; the state (present or absent) follows.
    sessionReadRejected ## The token was stale; no state was read.

  SessionReadResult* = object ## Fenced session-read outcome.
    ##
    ## Rejection is distinct from an empty read: a superseded owner is told its
    ## token is stale rather than being handed `none` and allowed to checkpoint on
    ## top of the new owner's state.
    case status*: SessionReadStatus
    of sessionRead:
      state*: Option[GatewaySessionState] ## Stored resume state, or `none`.
    of sessionReadRejected:
      discard

  IdentifyReservationStatus* = enum ## Outcome kind of `reserveIdentify`.
    identifyReserved, ## A non-refundable IDENTIFY permit was granted.
    identifyDeferred ## Budget or bucket timing requires a retry.

  IdentifyReservation* = object ## IDENTIFY permit decision with budget context.
    maxConcurrency*: uint16 ## Discord `max_concurrency`; number of buckets.
    remaining*: int ## Session-start permits left after this call.
    resetAfterMs*: int64 ## Nonnegative milliseconds until the permit budget
      ## resets to its full allowance.
    case status*: IdentifyReservationStatus
    of identifyReserved:
      lease*: IdentifyLease ## Granted, non-refundable IDENTIFY lease.
    of identifyDeferred:
      retryAfterMs*: int64 ## Nonnegative milliseconds to wait before a retry may
        ## succeed.

  WallClock* = proc(): int64 {.closure, gcsafe, raises: [].} ## Backend clock
    ## returning wall-clock milliseconds; injected so tests stay deterministic.

  ShardAcquireFuture* =
    Future[ShardAcquireResult].Raising([CancelledError, GatewayCoordinationError])
    ## `acquireShard` result: cancellation- and typed-failure-transparent.
  LeaseRenewFuture* =
    Future[LeaseRenewResult].Raising([CancelledError, GatewayCoordinationError])
    ## `renewShard` result: cancellation- and typed-failure-transparent.
  LeaseReleaseFuture* =
    Future[LeaseReleaseStatus].Raising([CancelledError, GatewayCoordinationError])
    ## `releaseShard` result: cancellation- and typed-failure-transparent.
  IdentifyReservationFuture* =
    Future[IdentifyReservation].Raising([CancelledError, GatewayCoordinationError])
    ## `reserveIdentify` result: cancellation- and typed-failure-transparent.
  SessionWriteFuture* =
    Future[SessionWriteStatus].Raising([CancelledError, GatewayCoordinationError])
    ## Conditional session-write result: cancellation/typed-failure-transparent.
  SessionReadFuture* =
    Future[SessionReadResult].Raising([CancelledError, GatewayCoordinationError])
    ## Fenced session-read result: cancellation/typed-failure-transparent.

  GatewayCoordination* = ref object ## Injectable distributed-coordination contract.
    ##
    ## A real backend supplies these closures; the facade procs below forward to
    ## them. Each closure is cancellation transparent: a backend that suspends
    ## propagates `CancelledError` to the caller unchanged.
    acquireShardProc: proc(shardId: ShardId): ShardAcquireFuture {.
      closure, gcsafe, raises: [].}
    renewShardProc: proc(lease: ShardLease): LeaseRenewFuture {.
      closure, gcsafe, raises: [].}
    releaseShardProc: proc(lease: ShardLease): LeaseReleaseFuture {.
      closure, gcsafe, raises: [].}
    reserveIdentifyProc: proc(shardId: ShardId): IdentifyReservationFuture {.
      closure, gcsafe, raises: [].}
    writeSessionProc: proc(
      lease: ShardLease; state: GatewaySessionState): SessionWriteFuture {.
      closure, gcsafe, raises: [].}
    readSessionProc: proc(lease: ShardLease): SessionReadFuture {.
      closure, gcsafe, raises: [].}

  LocalLease = object ## Internal active-lease record for the local adapter.
    token: FencingToken
    expiresAtMs: int64

  LocalGatewayCoordination* = ref object ## Single-process coordination adapter.
    ##
    ## One Chronos event-loop owner drives it; it performs no cross-process or
    ## cross-thread synchronization and is not a substitute for a real backend.
    ## It exists so the contract can be exercised deterministically: lease expiry
    ## and takeover, fencing-token rejection, and IDENTIFY bucket timing all key
    ## off one injected `WallClock`.
    clock: WallClock
    ttlMs: int64
    leases: Table[ShardId, LocalLease]
    nextToken: uint64
    identify: IdentifyCoordinator
    sessions: MemorySessionStore

func `==`*(a, b: FencingToken): bool {.borrow.}
  ## Compares fencing tokens for equality.
func `<`*(a, b: FencingToken): bool {.borrow.}
  ## Orders fencing tokens; a higher token supersedes a lower one.
func `$`*(token: FencingToken): string {.borrow.}
  ## Renders the token value for diagnostics; the token is not a secret.
func toUint64*(token: FencingToken): uint64 {.inline, raises: [].} =
  ## Returns the raw fencing value.
  uint64(token)

func code*(kind: CoordinationErrorKind): uint16 {.raises: [].} =
  ## Returns the stable numeric code for a failure category.
  ##
  ## Codes are contract-defined and never change for a given kind, so metrics and
  ## dashboards can key on them across adapter and library versions.
  case kind
  of ceUnavailable: 1'u16
  of ceConflict: 2'u16
  of ceProtocol: 3'u16
  of ceDenied: 4'u16
  of ceInternal: 5'u16

func name*(kind: CoordinationErrorKind): string {.raises: [].} =
  ## Returns the stable snake-case name for a failure category.
  case kind
  of ceUnavailable: "unavailable"
  of ceConflict: "conflict"
  of ceProtocol: "protocol"
  of ceDenied: "denied"
  of ceInternal: "internal"

proc newGatewayCoordinationError*(
    kind: CoordinationErrorKind; detail = ""): ref GatewayCoordinationError {.
    raises: [].} =
  ## Builds a typed coordination failure for a backend to raise.
  ##
  ## `detail` is adapter-specific and is never surfaced by `diagnostic`; keep it
  ## out of operator-facing sinks and use it only for privileged debugging.
  result = newException(GatewayCoordinationError, detail)
  result.kind = kind

func diagnostic*(error: ref GatewayCoordinationError): string {.raises: [].} =
  ## Renders a redaction-safe description: stable kind and code only.
  ##
  ## The adapter-specific message is deliberately omitted so a coordination
  ## failure can be logged without leaking backend reply fragments.
  if error.isNil:
    return "coordination_error(nil)"
  "coordination_error(kind=" & error.kind.name & ", code=" &
    $error.kind.code & ")"

func saturatingAddMs(base, delta: int64): int64 {.raises: [].} =
  ## Adds a duration to a timestamp, clamping at the `int64` bounds instead of
  ## wrapping, so a far-future TTL cannot fold an expiry into the past.
  if delta > 0 and base > high(int64) - delta:
    high(int64)
  elif delta < 0 and base < low(int64) - delta:
    low(int64)
  else:
    base + delta

func retryAfterMs(nowMs, futureMs: int64): int64 {.raises: [].} =
  ## Nonnegative milliseconds from `nowMs` until `futureMs`.
  ##
  ## A deadline already reached (or one folded into the past by clamping) yields
  ## zero rather than a negative or wrapped value. `nowMs` is a nonnegative wall
  ## clock, so the subtraction on the live path cannot overflow.
  if futureMs <= nowMs: 0'i64 else: futureMs - nowMs

proc newGatewayCoordination*(
    acquireShardProc: proc(shardId: ShardId): ShardAcquireFuture {.
      closure, gcsafe, raises: [].};
    renewShardProc: proc(lease: ShardLease): LeaseRenewFuture {.
      closure, gcsafe, raises: [].};
    releaseShardProc: proc(lease: ShardLease): LeaseReleaseFuture {.
      closure, gcsafe, raises: [].};
    reserveIdentifyProc: proc(shardId: ShardId): IdentifyReservationFuture {.
      closure, gcsafe, raises: [].};
    writeSessionProc: proc(
      lease: ShardLease; state: GatewaySessionState): SessionWriteFuture {.
      closure, gcsafe, raises: [].};
    readSessionProc: proc(lease: ShardLease): SessionReadFuture {.
      closure, gcsafe, raises: [].},
): GatewayCoordination {.raises: [ValueError].} =
  ## Builds a coordination contract from a complete set of backend closures.
  ##
  ## Raises `ValueError` rather than permit a partially wired contract that would
  ## fail during a live shard handover.
  if acquireShardProc.isNil or renewShardProc.isNil or releaseShardProc.isNil or
      reserveIdentifyProc.isNil or writeSessionProc.isNil or
      readSessionProc.isNil:
    raise newException(
      ValueError, "gateway coordination callbacks must not be nil")
  GatewayCoordination(
    acquireShardProc: acquireShardProc,
    renewShardProc: renewShardProc,
    releaseShardProc: releaseShardProc,
    reserveIdentifyProc: reserveIdentifyProc,
    writeSessionProc: writeSessionProc,
    readSessionProc: readSessionProc,
  )

proc acquireShard*(
    coordination: GatewayCoordination; shardId: ShardId): ShardAcquireFuture =
  ## Requests exclusive ownership of `shardId`.
  coordination.acquireShardProc(shardId)

proc renewShard*(
    coordination: GatewayCoordination; lease: ShardLease): LeaseRenewFuture =
  ## Extends a lease the caller still holds, presenting its exact fencing token.
  coordination.renewShardProc(lease)

proc releaseShard*(
    coordination: GatewayCoordination; lease: ShardLease): LeaseReleaseFuture =
  ## Releases a lease; a stale token leaves the current lease untouched.
  coordination.releaseShardProc(lease)

proc reserveIdentify*(
    coordination: GatewayCoordination;
    shardId: ShardId): IdentifyReservationFuture =
  ## Reserves one non-refundable IDENTIFY permit for `shardId`.
  coordination.reserveIdentifyProc(shardId)

proc writeSession*(
    coordination: GatewayCoordination;
    lease: ShardLease;
    state: GatewaySessionState): SessionWriteFuture =
  ## Conditionally persists resume state, keyed by shard plus fencing token.
  coordination.writeSessionProc(lease, state)

proc readSession*(
    coordination: GatewayCoordination; lease: ShardLease): SessionReadFuture =
  ## Reads the persisted resume state for the lease's shard under its fencing
  ## token; a superseded owner is rejected rather than handed stale state.
  coordination.readSessionProc(lease)

proc newLocalGatewayCoordination*(
    clock: WallClock;
    leaseTtlMs: int64;
    identifyLimit: SessionStartLimit,
): LocalGatewayCoordination {.raises: [ValueError].} =
  ## Creates a single-process coordination adapter, validating inputs once.
  ##
  ## Raises `ValueError` for a non-positive lease TTL, a nil clock, or Discord
  ## identify limits that are internally inconsistent.
  if clock.isNil:
    raise newException(ValueError, "coordination wall clock must not be nil")
  if leaseTtlMs <= 0:
    raise newException(ValueError, "shard lease TTL must be positive")
  let now = clock()
  LocalGatewayCoordination(
    clock: clock,
    ttlMs: leaseTtlMs,
    leases: initTable[ShardId, LocalLease](),
    identify: initIdentifyCoordinator(identifyLimit, now),
    sessions: initMemorySessionStore(),
  )

proc expireIfElapsed(
    local: LocalGatewayCoordination; shardId: ShardId; nowMs: int64) {.
    raises: [].} =
  ## Drops an active lease whose backend expiry has passed.
  ##
  ## Lazy expiry keeps renew and write safe: once a lease lapses its owner must
  ## re-acquire, so a paused owner cannot renew across a takeover boundary.
  if local.leases.hasKey(shardId) and
      nowMs >= local.leases.getOrDefault(shardId).expiresAtMs:
    local.leases.del(shardId)

proc acquireShard*(
    local: LocalGatewayCoordination;
    shardId: ShardId): Future[ShardAcquireResult] {.
    async: (raises: [CancelledError]).} =
  ## Grants a lease with a fresh fencing token when the shard is free.
  let now = local.clock()
  local.expireIfElapsed(shardId, now)
  if local.leases.hasKey(shardId):
    return ShardAcquireResult(
      status: shardHeld,
      retryAfterMs: retryAfterMs(
        now, local.leases.getOrDefault(shardId).expiresAtMs))
  inc local.nextToken
  let expiresAtMs = saturatingAddMs(now, local.ttlMs)
  let lease = ShardLease(
    shardId: shardId,
    token: FencingToken(local.nextToken),
    ttlMs: local.ttlMs,
  )
  local.leases[shardId] = LocalLease(
    token: lease.token, expiresAtMs: expiresAtMs)
  ShardAcquireResult(status: shardAcquired, lease: lease)

proc renewShard*(
    local: LocalGatewayCoordination;
    lease: ShardLease): Future[LeaseRenewResult] {.
    async: (raises: [CancelledError]).} =
  ## Extends expiry only for the exact current token; keeps the token unchanged.
  let now = local.clock()
  local.expireIfElapsed(lease.shardId, now)
  if local.leases.hasKey(lease.shardId) and
      local.leases.getOrDefault(lease.shardId).token == lease.token:
    let expiresAt = saturatingAddMs(now, local.ttlMs)
    local.leases[lease.shardId] = LocalLease(
      token: lease.token, expiresAtMs: expiresAt)
    return LeaseRenewResult(
      status: leaseRenewed,
      lease: ShardLease(
        shardId: lease.shardId,
        token: lease.token,
        ttlMs: local.ttlMs,
      ),
    )
  LeaseRenewResult(status: leaseLost)

proc releaseShard*(
    local: LocalGatewayCoordination;
    lease: ShardLease): Future[LeaseReleaseStatus] {.
    async: (raises: [CancelledError]).} =
  ## Clears the lease only for the exact current token.
  let now = local.clock()
  local.expireIfElapsed(lease.shardId, now)
  if local.leases.hasKey(lease.shardId) and
      local.leases.getOrDefault(lease.shardId).token == lease.token:
    local.leases.del(lease.shardId)
    return leaseReleased
  leaseReleaseRejected

proc reserveIdentify*(
    local: LocalGatewayCoordination;
    shardId: ShardId): Future[IdentifyReservation] {.
    async: (raises: [CancelledError]).} =
  ## Reserves one IDENTIFY permit under Discord's budget and bucket timing.
  ##
  ## A granted permit is non-refundable: there is deliberately no operation that
  ## returns it, on release or on any failure.
  let now = local.clock()
  let outcome = local.identify.tryAcquire(shardId, now)
  case outcome.kind
  of identifyAcquired:
    return IdentifyReservation(
      maxConcurrency: local.identify.maxConcurrency,
      remaining: local.identify.remaining,
      resetAfterMs: retryAfterMs(now, local.identify.resetAtMs),
      status: identifyReserved,
      lease: outcome.lease,
    )
  of identifyBudgetExhausted, identifyBucketCoolingDown:
    return IdentifyReservation(
      maxConcurrency: local.identify.maxConcurrency,
      remaining: local.identify.remaining,
      resetAfterMs: retryAfterMs(now, local.identify.resetAtMs),
      status: identifyDeferred,
      retryAfterMs: retryAfterMs(now, outcome.retryAtMs),
    )

proc writeSession*(
    local: LocalGatewayCoordination;
    lease: ShardLease;
    state: GatewaySessionState): Future[SessionWriteStatus] {.
    async: (raises: [CancelledError]).} =
  ## Persists resume state only under a matching, current fencing token.
  ##
  ## The state is copied by value into backend-owned storage, so no mutable
  ## alias to the caller's session escapes.
  if state.shardId != lease.shardId:
    return sessionWriteRejected
  let now = local.clock()
  local.expireIfElapsed(lease.shardId, now)
  if local.leases.hasKey(lease.shardId) and
      local.leases.getOrDefault(lease.shardId).token == lease.token:
    local.sessions.put(state)
    return sessionWritten
  sessionWriteRejected

proc readSession*(
    local: LocalGatewayCoordination;
    lease: ShardLease): Future[SessionReadResult] {.
    async: (raises: [CancelledError]).} =
  ## Returns a value copy of the stored resume state under a matching, current
  ## fencing token.
  ##
  ## A stale token is rejected so a superseded owner cannot read the new owner's
  ## resume state and checkpoint on top of it. Lazy expiry runs first, so a lapsed
  ## lease is treated as stale even before the shard is re-acquired.
  let now = local.clock()
  local.expireIfElapsed(lease.shardId, now)
  if local.leases.hasKey(lease.shardId) and
      local.leases.getOrDefault(lease.shardId).token == lease.token:
    return SessionReadResult(
      status: sessionRead, state: local.sessions.get(lease.shardId))
  SessionReadResult(status: sessionReadRejected)

proc asCoordination*(
    local: LocalGatewayCoordination): GatewayCoordination {.
    raises: [ValueError].} =
  ## Views the local adapter through the injectable contract facade.
  ##
  ## Each forwarder is an async bridge whose declared failure set is the contract's
  ## wide one (`CancelledError` plus `GatewayCoordinationError`), even though the
  ## local adapter it awaits only ever fails on cancellation. This keeps the local
  ## adapter's own procedures honestly typed as non-failing while still satisfying
  ## the contract a real, fallible backend must implement.
  newGatewayCoordination(
    acquireShardProc = proc(shardId: ShardId): Future[ShardAcquireResult] {.
        gcsafe, async: (raises: [CancelledError, GatewayCoordinationError]).} =
      return await local.acquireShard(shardId),
    renewShardProc = proc(lease: ShardLease): Future[LeaseRenewResult] {.
        gcsafe, async: (raises: [CancelledError, GatewayCoordinationError]).} =
      return await local.renewShard(lease),
    releaseShardProc = proc(lease: ShardLease): Future[LeaseReleaseStatus] {.
        gcsafe, async: (raises: [CancelledError, GatewayCoordinationError]).} =
      return await local.releaseShard(lease),
    reserveIdentifyProc = proc(shardId: ShardId): Future[IdentifyReservation] {.
        gcsafe, async: (raises: [CancelledError, GatewayCoordinationError]).} =
      return await local.reserveIdentify(shardId),
    writeSessionProc = proc(
        lease: ShardLease; state: GatewaySessionState): Future[SessionWriteStatus]
        {.gcsafe,
          async: (raises: [CancelledError, GatewayCoordinationError]).} =
      return await local.writeSession(lease, state),
    readSessionProc = proc(lease: ShardLease): Future[SessionReadResult] {.
        gcsafe, async: (raises: [CancelledError, GatewayCoordinationError]).} =
      return await local.readSession(lease),
  )
