## Deterministic tests for the multi-shard Gateway runtime supervisor.
##
## Runners are driven purely through injected coordination: a "running" shard
## blocks forever on a pending acquire (alive until closed), and a "failing" shard
## fails its acquire with a typed backend error. No transport is exercised, so the
## supervisor's start/fail-fast/restart/close behavior is isolated and exact.

import std/[options, strutils]

import chronos

import cordnim/core/secrets
import cordnim/gateway/[
  close_policy, compression, coordination, dispatch, dispatch_runtime, identify,
  payloads, session, sharding, shard_runner, runtime, transport, url]

type Timeline = ref object
  nowMs: int64

proc makeClock(tl: Timeline): GatewayClock =
  result = proc(): int64 {.gcsafe, raises: [].} = tl.nowMs

proc makeSleeper(tl: Timeline): GatewaySleeper =
  result = proc(ms: int64): GatewaySleepFuture {.gcsafe, raises: [].} =
    result = GatewaySleepFuture.init("rt.sleep")
    if ms <= 0: result.complete()

proc noJitter(): GatewayJitter =
  result = proc(span: int64): int64 {.gcsafe, raises: [].} = span

# A transport factory that is never invoked (runners block before connecting).
proc unusedFactory(): GatewayTransportFactory =
  result = proc(): GatewayTransportDriver {.gcsafe, raises: [].} =
    let onConnect = proc(url: string): GatewayDriverVoidFuture {.gcsafe, raises: [].} =
      result = GatewayDriverVoidFuture.init("rt.connect"); result.complete()
    let onSend = proc(msg: GatewayMessage): GatewayDriverVoidFuture {.gcsafe, raises: [].} =
      result = GatewayDriverVoidFuture.init("rt.send"); result.complete()
    let onReceive = proc(): Future[GatewayTransportEvent] {.gcsafe,
        async: (raises: [CancelledError, GatewayTransportError]).} =
      await noCancel(GatewaySleepFuture.init("rt.rx")) # never completes
      raise newException(GatewayTransportError, "unreachable")
    let onClose = proc(code: GatewayCloseCode; reason: string): GatewayDriverVoidFuture {.
        gcsafe, raises: [].} =
      result = GatewayDriverVoidFuture.init("rt.close"); result.complete()
    let onAbort = proc() {.gcsafe, raises: [].} = discard
    try:
      result = newGatewayTransportDriver(onConnect, onSend, onReceive, onClose, onAbort)
    except ValueError:
      raiseAssert "closures are non-nil"

# --- coordination stubs ---
proc okRenew(lease: ShardLease): LeaseRenewFuture {.gcsafe, raises: [].} =
  result = LeaseRenewFuture.init("rt.renew"); result.complete(
    LeaseRenewResult(status: leaseRenewed, lease: lease))
proc okRelease(lease: ShardLease): LeaseReleaseFuture {.gcsafe, raises: [].} =
  result = LeaseReleaseFuture.init("rt.rel"); result.complete(leaseReleased)
proc okReserve(shardId: ShardId): IdentifyReservationFuture {.gcsafe, raises: [].} =
  result = IdentifyReservationFuture.init("rt.res"); result.complete(
    IdentifyReservation(maxConcurrency: 1, remaining: 1, resetAfterMs: 1000,
      status: identifyReserved, lease: IdentifyLease(shardId: shardId, bucket: 0)))
proc okWrite(lease: ShardLease; state: GatewaySessionState): SessionWriteFuture {.
    gcsafe, raises: [].} =
  result = SessionWriteFuture.init("rt.write"); result.complete(sessionWritten)
proc okRead(lease: ShardLease): SessionReadFuture {.gcsafe, raises: [].} =
  result = SessionReadFuture.init("rt.read"); result.complete(
    SessionReadResult(status: sessionRead, state: none(GatewaySessionState)))

# Shared recorder of acquire order, so start ordering is observable.
var acquireOrder {.threadvar.}: seq[uint16]

proc recordingPendingAcquire(shardId: ShardId): ShardAcquireFuture {.gcsafe, raises: [].} =
  acquireOrder.add shardId.toUint16
  ShardAcquireFuture.init("rt.acq.pending") # never completes: shard stays alive

proc failingAcquire(shardId: ShardId): ShardAcquireFuture {.gcsafe, raises: [].} =
  acquireOrder.add shardId.toUint16 # count every attempt, including restarts
  result = ShardAcquireFuture.init("rt.acq.fail")
  result.fail(newGatewayCoordinationError(ceUnavailable, "redis-secret-detail"))

proc runningCoordination(): GatewayCoordination =
  newGatewayCoordination(
    recordingPendingAcquire, okRenew, okRelease, okReserve, okWrite, okRead)

proc failingCoordination(): GatewayCoordination =
  newGatewayCoordination(
    failingAcquire, okRenew, okRelease, okReserve, okWrite, okRead)

proc baseConfig(shardId: ShardId; total: uint16): GatewayShardRunnerConfig =
  GatewayShardRunnerConfig(
    shardId: shardId, totalShards: total,
    token: initSecret[BotToken]("t"),
    identifyProperties: initGatewayIdentifyProperties("linux", "c", "c"),
    intents: 0'u64, initialUrl: "wss://gateway.discord.gg/",
    compression: gatewayCompressionNone,
    helloTimeoutMs: 20_000, leaseRenewIntervalMs: 30_000, reconnectBackoffMs: 0)

proc makeRunner(
    tl: Timeline; shardId: ShardId; total: uint16;
    coord: GatewayCoordination): GatewayShardRunner =
  let dispatch = newGatewayDispatchRuntime(
    orderedPolicy(4), proc(e: DispatchEvent): Future[void] {.async.} = discard)
  newGatewayShardRunner(
    baseConfig(shardId, total), coord, dispatch, unusedFactory(),
    makeClock(tl), makeSleeper(tl), noJitter())

# Factory builders take `tl` as a parameter so the returned closures capture it
# (a gcsafe capture) rather than accessing a module-global.
proc mkRunningFactory(tl: Timeline; total: uint16): GatewayRunnerFactory =
  result = proc(shardId: ShardId): GatewayShardRunner {.
      gcsafe, raises: [ValueError, GatewayUrlError].} =
    makeRunner(tl, shardId, total, runningCoordination())

proc mkFailingFactory(tl: Timeline; total: uint16): GatewayRunnerFactory =
  result = proc(shardId: ShardId): GatewayShardRunner {.
      gcsafe, raises: [ValueError, GatewayUrlError].} =
    makeRunner(tl, shardId, total, failingCoordination())

proc mkFailFastFactory(
    tl: Timeline; failShard: ShardId; total: uint16): GatewayRunnerFactory =
  result = proc(shardId: ShardId): GatewayShardRunner {.
      gcsafe, raises: [ValueError, GatewayUrlError].} =
    let coord =
      if shardId == failShard: failingCoordination() else: runningCoordination()
    makeRunner(tl, shardId, total, coord)

proc mkMismatchFactory(tl: Timeline): GatewayRunnerFactory =
  result = proc(shardId: ShardId): GatewayShardRunner {.
      gcsafe, raises: [ValueError, GatewayUrlError].} =
    makeRunner(tl, ShardId(9), 16, runningCoordination())

proc mkWrongTotalFactory(tl: Timeline): GatewayRunnerFactory =
  # Correct shard id, but a total-shards count that disagrees with the plan.
  result = proc(shardId: ShardId): GatewayShardRunner {.
      gcsafe, raises: [ValueError, GatewayUrlError].} =
    makeRunner(tl, shardId, 16, runningCoordination())

block construction_validates_inputs:
  let tl = Timeline()
  let plan = planShards(2, 0, 1)
  doAssertRaises ValueError: # nil factory
    discard newGatewayRuntime(plan, nil)
  doAssertRaises ValueError: # negative restart budget
    discard newGatewayRuntime(
      plan, mkRunningFactory(tl, 2), GatewayRestartPolicy(maxRestarts: -1))
  doAssertRaises ValueError: # factory returns the wrong shard id
    discard newGatewayRuntime(plan, mkMismatchFactory(tl))
  doAssertRaises ValueError: # factory returns a mismatched total shard count
    discard newGatewayRuntime(plan, mkWrongTotalFactory(tl))
  let rt = newGatewayRuntime(plan, mkRunningFactory(tl, 2))
  doAssert rt.runnerCount == 2

block fail_fast_closes_all_and_reports_redaction_safe:
  acquireOrder = @[]
  let tl = Timeline()
  let rt = newGatewayRuntime(
    planShards(3, 0, 1), mkFailFastFactory(tl, ShardId(1), 3))
  var failed = false
  try:
    waitFor rt.run()
  except GatewayRuntimeError as err:
    failed = true
    doAssert err.msg.find("shard 1") != -1
    doAssert err.msg.find("secret") == -1 # backend detail never leaks
  doAssert failed
  doAssert rt.failureReason.len > 0

block deterministic_ascending_start_order:
  acquireOrder = @[]
  let tl = Timeline()
  let rt = newGatewayRuntime(planShards(3, 0, 1), mkRunningFactory(tl, 3))
  let runFut = rt.run()
  # Let each shard reach its (pending) acquire.
  for _ in 0 ..< 8: waitFor sleepAsync(0.milliseconds)
  doAssert acquireOrder == @[0'u16, 1, 2] # started in ascending shard order
  waitFor rt.close()
  waitFor runFut

block close_before_run_and_second_run:
  let tl = Timeline()
  let rt = newGatewayRuntime(planShards(2, 0, 1), mkRunningFactory(tl, 2))
  waitFor rt.close() # close before run
  waitFor rt.run() # returns immediately, nothing started
  # A second run is rejected.
  let rt2 = newGatewayRuntime(planShards(2, 0, 1), mkRunningFactory(tl, 2))
  let f = rt2.run()
  for _ in 0 ..< 4: waitFor sleepAsync(0.milliseconds)
  doAssertRaises GatewayRuntimeError:
    waitFor rt2.run()
  waitFor rt2.close()
  waitFor f

block concurrent_close_calls_join:
  let tl = Timeline()
  let rt = newGatewayRuntime(planShards(2, 0, 1), mkRunningFactory(tl, 2))
  let runFut = rt.run()
  for _ in 0 ..< 6: waitFor sleepAsync(0.milliseconds)
  let a = rt.close()
  let b = rt.close()
  waitFor a
  waitFor b
  waitFor runFut

block bounded_restart_budget_is_finite:
  # A shard that always fails is restarted at most `maxRestarts` times, then the
  # runtime fails fast instead of entering an infinite loop.
  acquireOrder = @[]
  let tl = Timeline()
  let rt = newGatewayRuntime(
    planShards(1, 0, 1), mkFailingFactory(tl, 1), GatewayRestartPolicy(maxRestarts: 2))
  var failed = false
  try:
    waitFor rt.run()
  except GatewayRuntimeError:
    failed = true
  doAssert failed
  # 1 initial attempt + 2 restarts = 3 acquire attempts, then it gives up.
  doAssert acquireOrder.len == 3

echo "tgateway_runtime: all blocks passed"
