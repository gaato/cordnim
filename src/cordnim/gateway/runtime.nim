## Supervisor for a planned set of Gateway shards.
##
## `GatewayRuntime` builds one `GatewayShardRunner` per owned shard, starts them
## in ascending order, and closes them in reverse order. The default policy is
## fail-fast. A configured restart budget can replace a failed runner only a
## finite number of times before the runtime reports a redacted terminal error.
##
## `start` creates the owned supervisor task, `join` observes its outcome without
## transferring cancellation, and `close` stops and joins the fleet. These
## operations map directly to an application's start, wait, and close hooks.

import chronos

import ../runtime/task_scope
import ./[session, sharding, shard_runner, url]

type
  GatewayRuntimeError* = object of CatchableError ## Terminal multi-shard failure.
    ## The message names the failing shard and a stable reason; it never contains
    ## payload, token, or backend text.

  GatewayRuntimeFailure* = object ## Redaction-safe failure metadata.
    shardId*: ShardId ## Shard whose terminal failure stopped the runtime.
    reason*: string ## Stable reason, safe to log.

  GatewayRuntimeObserver* = proc(failure: GatewayRuntimeFailure) {.
    gcsafe, raises: [].} ## Sink for the terminal runtime failure.

  GatewayRestartPolicy* = object ## Bounded restart budget for a failed shard.
    maxRestarts*: int ## Restarts allowed per shard before the runtime fails.
      ## Zero means pure fail-fast.

  GatewayRunnerFactory* = proc(shardId: ShardId): GatewayShardRunner {.
    gcsafe, raises: [ValueError, GatewayUrlError].} ## Builds one runner per shard.

  RuntimeRunTask = Future[void].Raising([CancelledError, GatewayRuntimeError])
    ## The owned supervisor task.

  GatewayRuntime* = ref object ## Supervisor owning one runner per planned shard.
    shardIds: seq[ShardId]
    runners: seq[GatewayShardRunner]
    factory: GatewayRunnerFactory
    restart: GatewayRestartPolicy
    observer: GatewayRuntimeObserver
    planTotalShards: uint16
    runTask: RuntimeRunTask
    scope: TaskScope
    aborted: AsyncEvent
    allDone: AsyncEvent
    shutdownComplete: AsyncEvent
    activeCount: int
    failed: bool
    failureReason: string
    failureShardId: ShardId
    started: bool
    closing: bool
    shutdownStarted: bool

func runnerCount*(runtime: GatewayRuntime): int {.inline, raises: [].} =
  ## Returns the number of supervised shard runners.
  runtime.runners.len

func failureReason*(runtime: GatewayRuntime): string {.inline, raises: [].} =
  ## Returns the redaction-safe terminal failure reason, or the empty string.
  runtime.failureReason

proc validateRunner(
    runner: GatewayShardRunner; shardId: ShardId; totalShards: uint16) {.
    raises: [ValueError].} =
  ## Rejects a factory result that is nil, bound to the wrong shard, or carrying
  ## a shard-set size that disagrees with the plan.
  ##
  ## The total-shards check keeps a runner from sending an IDENTIFY whose
  ## `[shard_id, num_shards]` pair contradicts the plan the fleet is sharded by.
  if runner.isNil:
    raise newException(ValueError, "gateway runner factory returned nil")
  if runner.shardId != shardId:
    raise newException(
      ValueError, "gateway runner factory returned a mismatched shard id")
  if runner.totalShards != totalShards:
    raise newException(
      ValueError,
      "gateway runner factory returned a mismatched total shard count")

proc newGatewayRuntime*(
    plan: ShardPlan;
    factory: GatewayRunnerFactory;
    restart = GatewayRestartPolicy();
    observer: GatewayRuntimeObserver = nil,
): GatewayRuntime {.raises: [ValueError, GatewayUrlError].} =
  ## Builds one runner per owned shard, in ascending shard order.
  ##
  ## Raises `ValueError` for a nil factory, a negative restart budget, or a
  ## factory result that is nil or bound to the wrong shard, and propagates a
  ## factory's construction error unchanged.
  if factory.isNil:
    raise newException(ValueError, "gateway runner factory must not be nil")
  if restart.maxRestarts < 0:
    raise newException(ValueError, "restart budget must not be negative")
  result = GatewayRuntime(
    factory: factory,
    restart: restart,
    observer: observer,
    planTotalShards: plan.totalShards,
    scope: newTaskScope(),
    aborted: newAsyncEvent(),
    allDone: newAsyncEvent(),
    shutdownComplete: newAsyncEvent(),
  )
  for id in plan.shardIds:
    let runner = factory(id)
    validateRunner(runner, id, plan.totalShards)
    result.shardIds.add id
    result.runners.add runner

proc joinAll(futs: seq[FutureBase]) {.async: (raises: []).} =
  ## Cancels any unfinished futures and awaits every one, leaving none pending.
  var pending: seq[FutureBase]
  for fut in futs:
    if not fut.isNil:
      if not fut.finished:
        fut.cancelSoon()
      pending.add fut
  if pending.len > 0:
    await noCancel(allFutures(pending))

proc recordFailure(
    runtime: GatewayRuntime; shardId: ShardId; reason: string) {.raises: [].} =
  ## Records the first terminal failure and unblocks the run.
  if not runtime.failed:
    runtime.failed = true
    runtime.failureShardId = shardId
    runtime.failureReason = "shard " & $shardId.toUint16 & ": " & reason
    if not runtime.observer.isNil:
      runtime.observer(
        GatewayRuntimeFailure(shardId: shardId, reason: reason))
  runtime.aborted.fire()

proc childStopped(runtime: GatewayRuntime) {.raises: [].} =
  ## Marks one shard as stopped; signals once every shard has stopped.
  if runtime.activeCount > 0:
    dec runtime.activeCount
  if runtime.activeCount <= 0:
    runtime.allDone.fire()

proc superviseChild(
    runtime: GatewayRuntime; index: int) {.async: (raises: []).} =
  ## Runs one shard, applying the bounded restart budget before failing the run.
  var attemptsLeft = runtime.restart.maxRestarts
  while true:
    try:
      await runtime.runners[index].run()
      # A normal return means the runner was closed; a clean stop, not a failure.
      runtime.childStopped()
      return
    except CancelledError:
      # Shutdown cancellation; ownership is being torn down elsewhere.
      return
    except GatewayShardRunnerError as exc:
      if attemptsLeft > 0 and not runtime.closing:
        dec attemptsLeft
        var rebuilt: GatewayShardRunner
        try:
          rebuilt = runtime.factory(runtime.shardIds[index])
        except CatchableError:
          runtime.recordFailure(
            runtime.shardIds[index], "runner rebuild failed")
          return
        if rebuilt.isNil or rebuilt.shardId != runtime.shardIds[index] or
            rebuilt.totalShards != runtime.planTotalShards:
          runtime.recordFailure(
            runtime.shardIds[index], "runner rebuild produced an invalid runner")
          return
        runtime.runners[index] = rebuilt
        continue
      # Budget exhausted (or none): fail the whole runtime fast. `exc.msg` is the
      # runner's stable, redaction-safe reason.
      runtime.recordFailure(runtime.shardIds[index], exc.msg)
      return

proc doShutdown(runtime: GatewayRuntime) {.async: (raises: []).} =
  ## The one-time teardown body; run uncancellably by `shutdown`.
  for index in countdown(runtime.runners.high, 0):
    await runtime.runners[index].close()
  await runtime.scope.cancelAndJoin()
  runtime.shutdownComplete.fire()

proc shutdown(runtime: GatewayRuntime) {.async: (raises: []).} =
  ## Runs teardown exactly once; every caller awaits the same completion.
  if not runtime.shutdownStarted:
    runtime.shutdownStarted = true
    await noCancel(runtime.doShutdown())
  else:
    await noCancel(runtime.shutdownComplete.wait())

proc superviseAll(runtime: GatewayRuntime) {.
    async: (raises: [CancelledError, GatewayRuntimeError]).} =
  ## The owned supervisor body: start every shard, wait for all-stopped or a
  ## terminal failure, then tear the fleet down. Its finally always runs shutdown.
  try:
    runtime.activeCount = runtime.runners.len
    # Deterministic start order: ascending shard id.
    for index in 0 ..< runtime.runners.len:
      if runtime.closing:
        # Closed mid-start: the remaining shards never run, so count them stopped
        # rather than leaving `allDone` forever unmet.
        runtime.childStopped()
        continue
      try:
        discard runtime.scope.spawn(runtime.superviseChild(index))
      except ValueError:
        # The scope was closed by a concurrent shutdown; the child never started.
        runtime.childStopped()
    let doneFut = runtime.allDone.wait()
    let abortFut = runtime.aborted.wait()
    try:
      discard await race(FutureBase(doneFut), FutureBase(abortFut))
    finally:
      await joinAll(@[FutureBase(doneFut), FutureBase(abortFut)])
  except CancelledError:
    # Close cancels the supervisor task; that is a graceful stop. Only a genuine
    # external cancellation (not via close) propagates, so the owned task ends in
    # a normal state whenever `close` joins it.
    if not runtime.closing:
      raise
  finally:
    await runtime.shutdown()
  if runtime.failed and not runtime.closing:
    raise newException(GatewayRuntimeError, runtime.failureReason)

proc start*(runtime: GatewayRuntime) {.raises: [GatewayRuntimeError].} =
  ## Starts the fleet as a single owned supervisor task. One-shot.
  ##
  ## Raises `GatewayRuntimeError` on a second start. A start after `close`, or of
  ## an empty plan, is a no-op.
  if runtime.started:
    raise newException(GatewayRuntimeError, "gateway runtime already started")
  runtime.started = true
  if runtime.closing or runtime.runners.len == 0:
    return
  runtime.runTask = superviseAll(runtime)

proc join*(runtime: GatewayRuntime) {.
    async: (raises: [CancelledError, GatewayRuntimeError]).} =
  ## Awaits the owned supervisor task and re-raises its terminal failure.
  ##
  ## Detached: cancelling a joiner neither stops the fleet nor affects other
  ## joiners. Use `close` to stop the fleet.
  if runtime.runTask.isNil:
    return
  if not runtime.runTask.finished:
    let signal = newAsyncEvent()
    proc wake(arg: pointer) {.gcsafe, raises: [].} = signal.fire()
    runtime.runTask.addCallback(wake)
    try:
      await signal.wait()
    finally:
      runtime.runTask.removeCallback(wake)
  if runtime.runTask.failed:
    var err: ref CatchableError
    try:
      err = runtime.runTask.readError()
    except FutureError:
      err = nil
    if not err.isNil and err of GatewayRuntimeError:
      raise (ref GatewayRuntimeError)(err)

proc run*(runtime: GatewayRuntime) {.
    async: (raises: [CancelledError, GatewayRuntimeError]).} =
  ## Starts every shard and joins the fleet: `start` then `join`.
  ##
  ## Returns normally once every shard stops cleanly (via `close`); raises
  ## `GatewayRuntimeError` when a shard fails past its restart budget. Cancelling
  ## `run` stops the join, not the fleet; call `close` to stop the fleet.
  runtime.start()
  await runtime.join()

proc close*(runtime: GatewayRuntime) {.async: (raises: []).} =
  ## Closes every supervised shard and releases resources.
  ##
  ## Cancels and joins the owned supervisor task so `close` returns only after the
  ## fleet has fully stopped. Idempotent and join-safe.
  runtime.closing = true
  runtime.aborted.fire()
  if not runtime.runTask.isNil and not runtime.runTask.finished:
    runtime.runTask.cancelSoon()
    try:
      await noCancel(runtime.runTask)
    except CatchableError:
      discard
  await runtime.shutdown()
