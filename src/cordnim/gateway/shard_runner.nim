## Asynchronous owner of one Gateway v10 shard.
##
## `GatewayShardRunner` owns the fenced shard lease, session cursor, transport,
## streaming decoder, heartbeat work, and bounded dispatch runtime. Its initial
## Gateway URL, coordination backend, transport factory, clocks, sleep, and jitter
## are injected; constructing or starting a runner performs no hidden REST call.
##
## A run chooses RESUME when fenced session state permits it and otherwise
## reserves a non-refundable IDENTIFY permit. Dispatch sequence state advances
## only after bounded admission. Lease loss, rejected session persistence, or a
## terminal close fails the run with redacted metadata.
##
## `start` creates the one owned run task, `join` observes it without transferring
## cancellation, and `close` stops and joins all retained work. A runner is
## one-shot.

import std/[json, options, strutils]

import chronos

import ../core/secrets
import ../runtime/task_scope
import ./[
  close_policy, compression, coordination, dispatch_runtime, payloads,
  session, supervisor, transport, url]

type
  GatewayShardRunnerError* = object of CatchableError ## Terminal shard-runner
    ## failure. Its message is a stable, redaction-safe reason; it never contains
    ## payload bytes, tokens, or a backend's exception text.

  GatewayClock* = proc(): int64 {.gcsafe, raises: [].}
    ## Monotonic milliseconds source for heartbeat scheduling.
  GatewaySleepFuture* = Future[void].Raising([CancelledError])
    ## Cancellation-only sleep result.
  RunTaskFuture = Future[void].Raising([CancelledError, GatewayShardRunnerError])
    ## The owned internal run-loop task.
  GatewaySleeper* = proc(durationMs: int64): GatewaySleepFuture {.
    gcsafe, raises: [].} ## Injectable delay; cancellation ends any wait.
  GatewayJitter* = proc(spanMs: int64): int64 {.gcsafe, raises: [].}
    ## Returns a value in `0 .. spanMs`; used for first-heartbeat and backoff.
  GatewayTransportFactory* = proc(): GatewayTransportDriver {.gcsafe, raises: [].}
    ## Produces one fresh driver per connection attempt.

  GatewayShardErrorContext* = object ## Redaction-safe shard-failure metadata.
    shardId*: ShardId ## Shard the failure belongs to.
    reason*: string ## Stable reason; never payload, token, or backend text.
  GatewayShardErrorObserver* = proc(context: GatewayShardErrorContext) {.
    gcsafe, raises: [].} ## Sink for shard and interaction-worker failures.

  GatewayShardRunnerConfig* = object ## Static, non-injected shard parameters.
    shardId*: ShardId ## Shard this runner owns.
    totalShards*: uint16 ## Advertised shard-set size for IDENTIFY.
    token*: Secret[BotToken] ## Bot token, redacted by normal renderers.
    identifyProperties*: GatewayIdentifyProperties ## IDENTIFY client metadata.
    intents*: uint64 ## Gateway intent bit mask.
    initialUrl*: string ## Initial Gateway base URL (canonicalized on use).
    compression*: GatewayCompression ## Transport compression mode.
    helloTimeoutMs*: int64 ## Bound within which HELLO must arrive.
    leaseRenewIntervalMs*: int64 ## Interval between lease renew/checkpoint.
    reconnectBackoffMs*: int64 ## Base backoff before a reconnect attempt.

  GatewayInteractionSink* = proc(interaction: JsonNode; receivedAtMs: int64):
      Future[void] {.gcsafe, raises: [].}
    ## Direct ingress for `INTERACTION_CREATE`. The runner admits an owned copy to
    ## a bounded runner-lifetime queue. It never constructs a public DispatchEvent.

  InteractionDispatchEnvelope = object ## Runner-owned queued interaction.
    interaction: JsonNode
    receivedAtMs: int64

  ConnectionOutcome = enum ## What to do after a connection ends.
    ocResume, ## Reconnect and RESUME from the last accepted cursor.
    ocIdentify, ## Reconnect and IDENTIFY a new session.
    ocTerminal ## Stop; do not reconnect.

  ConnectionState = ref object ## Mutable state shared by one connection's tasks.
    transport: GatewayTransport
    decoder: GatewayMessageDecoder
    watchdog: HeartbeatWatchdog
    outcome: ConnectionOutcome
    outcomeSet: bool
    done: AsyncEvent ## Fired once by the first task to reach an outcome.

  GatewayShardRunner* = ref object ## Async owner of one Gateway shard.
    config: GatewayShardRunnerConfig
    coordination: GatewayCoordination
    dispatch: GatewayDispatchRuntime
    interactionSink: GatewayInteractionSink ## Optional direct interaction ingress.
    interactionMaxConcurrent: int
      ## Independent worker bound for acknowledgement-deadline-sensitive work.
    interactionQueue: AsyncQueue[InteractionDispatchEnvelope]
      ## Bounded runner-lifetime queue; never owned by a connection scope.
    transportFactory: GatewayTransportFactory
    clock: GatewayClock
    sleeper: GatewaySleeper
    jitter: GatewayJitter
    observer: GatewayShardErrorObserver
    canonicalInitialUrl: string
    session: GatewaySessionState
    lease: ShardLease
    hasLease: bool
    leaseExpiryAtMs: int64 ## Conservative monotonic time the lease expires.
    runTask: RunTaskFuture ## The single owned run-loop task; close cancels/joins it.
    runScope: TaskScope ## Owns the lease renewal/ownership watchdog.
    activeConnScope: TaskScope ## Owns the current reader + heartbeat.
    activeTransport: GatewayTransport ## Current transport, for abort on shutdown.
    abortEvent: AsyncEvent ## Fired to unblock the run on fatal or close.
    lifecyclePhase: ShardLifecycle
    started: bool ## One-shot guard; a runner runs at most once.
    closing: bool
    fatal: bool
    fatalReason: string
    shutdownStarted: bool ## Whether teardown has begun.
    shutdownComplete: AsyncEvent ## Fired once teardown finishes; shared join point.

func lifecycle*(runner: GatewayShardRunner): ShardLifecycle {.
    inline, raises: [].} =
  ## Returns the observable lifecycle phase of the shard.
  runner.lifecyclePhase

func shardId*(runner: GatewayShardRunner): ShardId {.inline, raises: [].} =
  ## Returns the shard this runner owns.
  runner.config.shardId

func totalShards*(runner: GatewayShardRunner): uint16 {.inline, raises: [].} =
  ## Returns the advertised shard-set size this runner sends in IDENTIFY.
  runner.config.totalShards

func sessionSnapshot*(runner: GatewayShardRunner): GatewaySessionState {.
    raises: [].} =
  ## Returns a copy of the current resume state for observability and tests.
  runner.session

proc newGatewayShardRunner*(
    config: GatewayShardRunnerConfig;
    coordination: GatewayCoordination;
    dispatch: GatewayDispatchRuntime;
    transportFactory: GatewayTransportFactory;
    clock: GatewayClock;
    sleeper: GatewaySleeper;
    jitter: GatewayJitter;
    errorObserver: GatewayShardErrorObserver = nil;
    interactionSink: GatewayInteractionSink = nil,
    interactionMaxConcurrent: int = 4,
): GatewayShardRunner {.raises: [ValueError, GatewayUrlError].} =
  ## Builds a stopped runner, validating injected dependencies and the URL once.
  ##
  ## `INTERACTION_CREATE` never enters the generic dispatch runtime. With a sink,
  ## it is queued before the resume cursor advances. Without one, it is ignored.
  ## `interactionMaxConcurrent` bounds independent sink calls so one slow
  ## acknowledgement cannot head-of-line block every later interaction.
  if coordination.isNil or dispatch.isNil or transportFactory.isNil or
      clock.isNil or sleeper.isNil or jitter.isNil:
    raise newException(
      ValueError, "gateway shard runner dependencies must not be nil")
  if config.helloTimeoutMs <= 0 or config.leaseRenewIntervalMs <= 0:
    raise newException(
      ValueError, "gateway shard runner timeouts must be positive")
  if config.reconnectBackoffMs < 0:
    raise newException(
      ValueError, "reconnect backoff must not be negative")
  if config.totalShards == 0:
    raise newException(ValueError, "total shard count must be at least one")
  if config.shardId.toUint16 >= config.totalShards:
    raise newException(
      ValueError, "shard id must be less than the total shard count")
  if interactionMaxConcurrent <= 0:
    raise newException(
      ValueError, "interaction concurrency must be positive")
  result = GatewayShardRunner(
    config: config,
    coordination: coordination,
    dispatch: dispatch,
    interactionSink: interactionSink,
    interactionMaxConcurrent: interactionMaxConcurrent,
    transportFactory: transportFactory,
    clock: clock,
    sleeper: sleeper,
    jitter: jitter,
    observer: errorObserver,
    canonicalInitialUrl: buildGatewayUrl(
      config.initialUrl, config.compression == gatewayCompressionZlibStream),
    session: initGatewaySession(config.shardId),
    runScope: newTaskScope(),
    abortEvent: newAsyncEvent(),
    shutdownComplete: newAsyncEvent(),
    lifecyclePhase: shardStopped,
  )
  if not interactionSink.isNil:
    result.interactionQueue = newAsyncQueue[InteractionDispatchEnvelope](
      max(1, dispatch.aggregateQueueCapacity()))

proc fail(runner: GatewayShardRunner; reason: string) {.raises: [].} =
  ## Marks the run fatal with a stable reason and unblocks it. First reason wins.
  if not runner.fatal:
    runner.fatal = true
    runner.fatalReason = reason
    if not runner.observer.isNil:
      runner.observer(GatewayShardErrorContext(
        shardId: runner.config.shardId, reason: reason))
  runner.abortEvent.fire()

proc reportInteractionFailure(runner: GatewayShardRunner) {.raises: [].} =
  ## Reports stable metadata only; handler exceptions can contain interaction data.
  if not runner.observer.isNil:
    runner.observer(GatewayShardErrorContext(
      shardId: runner.config.shardId,
      reason: "interaction handler failed"))

proc runInteractionQueue(runner: GatewayShardRunner) {.
    async: (raises: []).} =
  ## Drains admitted interactions for the runner lifetime, across reconnects.
  while true:
    var queued: InteractionDispatchEnvelope
    try:
      queued = await runner.interactionQueue.get()
    except CancelledError:
      break
    try:
      await runner.interactionSink(queued.interaction, queued.receivedAtMs)
    except CancelledError:
      if runner.closing:
        break
      runner.reportInteractionFailure()
    except CatchableError:
      runner.reportInteractionFailure()

proc finish(
    state: ConnectionState; outcome: ConnectionOutcome) {.raises: [].} =
  ## Records the first connection outcome and signals the coordinator.
  if not state.outcomeSet:
    state.outcomeSet = true
    state.outcome = outcome
    state.done.fire()

proc outcomeOr(
    state: ConnectionState; fallback: ConnectionOutcome): ConnectionOutcome {.
    raises: [].} =
  if state.outcomeSet: state.outcome else: fallback

proc sleepFor(runner: GatewayShardRunner; ms: int64): Future[bool] {.
    async: (raises: []).} =
  ## Sleeps a non-negative span, returning false only when cancelled.
  try:
    await runner.sleeper(max(0'i64, ms))
    return true
  except CancelledError:
    return false

proc joinAll(futs: seq[FutureBase]) {.async: (raises: []).} =
  ## Cancels any unfinished futures and awaits every one to completion.
  ##
  ## Unlike `cancelSoon`, this leaves no unowned future pending after teardown;
  ## `noCancel` keeps the join itself from being interrupted mid-shutdown.
  var pending: seq[FutureBase]
  for fut in futs:
    if not fut.isNil:
      if not fut.finished:
        fut.cancelSoon()
      pending.add fut
  if pending.len > 0:
    await noCancel(allFutures(pending))

const minCoordinationRetryMs = 25'i64
  ## Floor for coordination retry waits, so a backend returning a zero
  ## `retryAfterMs` cannot spin the acquire/reserve loops.

const minReconnectBackoffMs = 10'i64
  ## Floor for the reconnect backoff wait, so a zero configured backoff cannot
  ## spin the connect/reconnect loop.

const shutdownReleaseBudgetMs = 5_000'i64
  ## Upper bound on how long shutdown waits for the lease release, so a
  ## never-completing release cannot hang close; backend TTL expiry is the
  ## safety fallback that frees the shard afterward.

func saturatingAddMs(base, delta: int64): int64 {.raises: [].} =
  ## Adds a nonnegative duration to a timestamp, clamping at `int64.high` rather
  ## than overflowing a bounded deadline into the past.
  if delta > 0 and base > high(int64) - delta:
    high(int64)
  else:
    base + delta

proc interruptibleSleep(
    runner: GatewayShardRunner; ms: int64): Future[bool] {.
    async: (raises: [CancelledError]).} =
  ## Waits up to `ms`, but wakes immediately on close/fatal so acquire, reserve,
  ## and backoff waits end promptly. Returns true only if the full span elapsed
  ## with the runner still live; external cancellation propagates.
  if runner.closing or runner.fatal:
    return false
  let sleepFut = runner.sleeper(max(0'i64, ms))
  let abortFut = runner.abortEvent.wait()
  var elapsed = false
  try:
    let winner = await race(FutureBase(sleepFut), FutureBase(abortFut))
    elapsed = winner == FutureBase(sleepFut)
  except CancelledError:
    await joinAll(@[FutureBase(sleepFut), FutureBase(abortFut)])
    raise
  await joinAll(@[FutureBase(sleepFut), FutureBase(abortFut)])
  return elapsed and not runner.closing and not runner.fatal

proc recordLease(
    runner: GatewayShardRunner; lease: ShardLease; nowMs: int64): bool {.
    raises: [].} =
  ## Records a granted or renewed lease and its conservative local expiry.
  ##
  ## `lease.ttlMs` is the lease's remaining lifetime, so the expiry is `nowMs +
  ## ttlMs` on the runner's monotonic clock. Returns false for a non-positive TTL,
  ## which cannot bound ownership and must fail the run closed.
  if lease.ttlMs <= 0:
    return false
  runner.lease = lease
  runner.hasLease = true
  runner.leaseExpiryAtMs = saturatingAddMs(nowMs, lease.ttlMs)
  true

proc rpcBeforeDeadline(
    runner: GatewayShardRunner; rpc: FutureBase; deadlineMs: int64): Future[bool] {.
    async: (raises: [CancelledError]).} =
  ## Races an in-flight coordination RPC against a monotonic deadline.
  ##
  ## Returns true if the RPC finished before the deadline (the caller then reads
  ## its typed result); false if the deadline elapsed first, in which case the RPC
  ## has been cancelled and joined so nothing is left pending. This is what stops
  ## a never-completing renew/read/write from letting a stale owner outlive its
  ## lease.
  let timer = runner.sleeper(max(1'i64, deadlineMs - runner.clock()))
  var winner: FutureBase
  try:
    winner = await race(rpc, FutureBase(timer))
  except CancelledError:
    await joinAll(@[rpc, FutureBase(timer)])
    raise
  if winner == rpc:
    await joinAll(@[FutureBase(timer)]) # cancel + join the loser timer only
    return true
  await joinAll(@[rpc, FutureBase(timer)]) # deadline won: cancel + join the RPC
  return false

proc leaseValid(runner: GatewayShardRunner): bool {.raises: [].} =
  ## True only while the runner still holds a lease that has not locally expired.
  ##
  ## Read immediately before any action that asserts ownership (connect, IDENTIFY
  ## or RESUME, dispatch admission), so an event-loop or GC stall past the TTL
  ## cannot let a stale owner act before the renewal watchdog fails closed.
  runner.hasLease and not runner.fatal and not runner.closing and
    runner.clock() < runner.leaseExpiryAtMs

proc rpcOrAbort(
    runner: GatewayShardRunner; rpc: FutureBase): Future[bool] {.
    async: (raises: [CancelledError]).} =
  ## Races an in-flight RPC or connect against the runner's abort signal.
  ##
  ## Returns true if the operation finished, or false if the run was aborted (a
  ## watchdog fail-closed or a close). In that case the operation is cancelled
  ## and joined. This is what lets a lease loss during any pre-main-loop phase
  ## terminate the run instead of parking it on a never-completing backend call.
  if runner.fatal or runner.closing:
    await joinAll(@[rpc])
    return false
  let abortFut = runner.abortEvent.wait()
  var winner: FutureBase
  try:
    winner = await race(rpc, FutureBase(abortFut))
  except CancelledError:
    await joinAll(@[rpc, FutureBase(abortFut)])
    raise
  if winner == rpc:
    await joinAll(@[FutureBase(abortFut)])
    return true
  await joinAll(@[rpc, FutureBase(abortFut)])
  return false

func guildScopeField(eventName: string): string {.raises: [].} =
  ## Selects the field naming an event's guild, by Discord event semantics.
  ##
  ## Guild lifecycle events carry the guild in `d.id`; every other guild-scoped
  ## event (members, channels, threads, messages, roles, ...) carries it in
  ## `d.guild_id`. Using the right field keeps all events for one guild on one
  ## partition lane, so a later GUILD_CREATE cannot be reordered ahead of an
  ## earlier update to the same guild's cached state.
  case eventName
  of "GUILD_CREATE", "GUILD_UPDATE", "GUILD_DELETE": "id"
  else: "guild_id"

proc gatewayPartitionKey*(eventName: string; data: JsonNode): uint64 {.
    raises: [].} =
  ## Derives a partition-ordering key for a dispatch from its guild identity.
  ##
  ## Returns zero for events with no guild scope, and also for a malformed guild
  ## id. The cache layer rejects that payload, so collapsing it to lane
  ## zero cannot corrupt a real guild's ordering.
  if data.isNil or data.kind != JObject:
    return 0'u64
  let node = data{guildScopeField(eventName)}
  if node.isNil or node.kind != JString:
    return 0'u64
  try:
    uint64(parseBiggestUInt(node.getStr()))
  except ValueError:
    0'u64

proc sendFrame(
    runner: GatewayShardRunner; state: ConnectionState; text: string,
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Sends one text frame, mapping a transport failure to a resume outcome and
  ## letting cancellation propagate. Never leaks payload or credentials.
  try:
    await state.transport.sendText(text)
    return true
  except CancelledError:
    raise
  except CatchableError:
    state.finish(ocResume)
    return false

proc sendHeartbeat(
    runner: GatewayShardRunner; state: ConnectionState): Future[bool] {.
    async: (raises: [CancelledError]).} =
  ## Sends an OP1 heartbeat carrying the last accepted sequence.
  var text: string
  try:
    text = $initGatewayHeartbeat(runner.session.sequence).toJson()
  except CatchableError:
    state.finish(ocResume)
    return false
  return await runner.sendFrame(state, text)

proc adoptReady(
    runner: GatewayShardRunner; state: ConnectionState; data: JsonNode;
    sequence: GatewaySequence,
): Future[bool] {.async: (raises: []).} =
  ## Adopts and checkpoints a new READY session, after dispatch admission only.
  if data.isNil or data.kind != JObject or
      not data.hasKey("session_id") or not data.hasKey("resume_gateway_url"):
    state.finish(ocResume)
    return false
  # recordReady clears the prior epoch's cursor, so the READY sequence must be
  # observed *after* it or it would be discarded.
  try:
    runner.session.recordReady(
      data{"session_id"}.getStr(), data{"resume_gateway_url"}.getStr())
  except ValueError:
    state.finish(ocResume)
    return false
  discard runner.session.observeSequence(sequence)
  # Checkpoint the new session under the lease; a rejection means the lease was
  # taken over and the run must fail closed.
  try:
    let written = await runner.coordination.writeSession(
      runner.lease, runner.session)
    if written != sessionWritten:
      runner.fail("session checkpoint rejected")
      state.finish(ocTerminal)
      return false
  except CancelledError:
    return false
  except GatewayCoordinationError:
    runner.fail("coordination backend error on checkpoint")
    state.finish(ocTerminal)
    return false
  except CatchableError:
    runner.fail("session checkpoint failed")
    state.finish(ocTerminal)
    return false
  runner.lifecyclePhase = shardReady
  return true

proc handleDispatch(
    runner: GatewayShardRunner; state: ConnectionState;
    dispatch: GatewayDispatchPayload,
): Future[bool] {.async: (raises: []).} =
  ## Submits a dispatch; only after admission is sequence/READY state advanced.
  ##
  ## Ownership is checked immediately before admission: if the lease has locally
  ## expired (for example the reader ran after a stall, before the renewal
  ## watchdog), the event is neither submitted nor sequenced and the run fails
  ## closed, so a stale owner never dispatches.
  if not runner.leaseValid:
    runner.fail("lease expired before dispatch admission")
    state.finish(ocTerminal)
    return false
  let eventName = dispatch.eventName.toString()

  if eventName == "INTERACTION_CREATE":
    # This branch is unconditional: an interaction never becomes a public
    # DispatchEvent, even when no high-level interaction runtime is attached.
    # Without a sink it is deliberately ignored. With a sink, admission moves an
    # owned copy to a bounded runner-lifetime queue before the resume cursor moves.
    if runner.interactionSink.isNil:
      discard runner.session.observeSequence(dispatch.sequence)
      return true
    let receivedAt = runner.clock()
    try:
      runner.interactionQueue.putNoWait(InteractionDispatchEnvelope(
        interaction: dispatch.data.copy(), receivedAtMs: receivedAt))
    except AsyncQueueFullError:
      # Resume from the last admitted sequence. The event was not accepted and
      # can be replayed without duplicating an admitted handler execution.
      state.finish(ocResume)
      return false
    discard runner.session.observeSequence(dispatch.sequence)
    return true

  var event: DispatchEvent
  try:
    event = initDispatchEvent(
      eventName, runner.config.shardId, dispatch.sequence,
      gatewayPartitionKey(eventName, dispatch.data), $dispatch.data,
      receivedAtMs = runner.clock())
  except ValueError:
    state.finish(ocResume)
    return false
  case runner.dispatch.submit(event)
  of dispatchAccepted:
    if eventName == "READY":
      return await runner.adoptReady(state, dispatch.data, dispatch.sequence)
    discard runner.session.observeSequence(dispatch.sequence)
    return true
  of dispatchOverloaded:
    # An overflowed event was never queued; abort and RESUME from the last
    # accepted cursor rather than skip it.
    state.finish(ocResume)
    return false
  of dispatchNotStarted, dispatchClosed:
    runner.fail("dispatch runtime unavailable")
    state.finish(ocTerminal)
    return false

proc handleClose(
    runner: GatewayShardRunner; state: ConnectionState;
    info: GatewayCloseInfo) {.raises: [].} =
  ## Maps a peer close to a reconnect outcome via the shared close policy.
  let decision = classifyGatewayClose(info.code)
  case decision.action
  of stopReconnecting:
    # A terminal close fails the run closed; record a stable, safe reason (the
    # close code is not sensitive) so the observer is notified.
    runner.fail("terminal gateway close code " & $info.code.toUint16)
    state.finish(ocTerminal)
  of identifyNewSession:
    runner.session.invalidate()
    state.finish(ocIdentify)
  of resumeSession:
    state.finish(if runner.session.canResume: ocResume else: ocIdentify)

proc handlePayload(
    runner: GatewayShardRunner; state: ConnectionState; node: JsonNode,
): Future[bool] {.async: (raises: []).} =
  ## Dispatches one decoded payload to its opcode handler.
  var payload: GatewayPayload
  try:
    payload = decodeGatewayPayload(node)
  except CatchableError:
    state.finish(ocResume)
    return false
  case payload.kind
  of GatewayPayloadKind.Dispatch:
    return await runner.handleDispatch(state, payload.dispatch)
  of GatewayPayloadKind.Heartbeat:
    # A server-requested heartbeat is sent immediately and does not shift the
    # periodic schedule.
    state.watchdog.serverHeartbeatSent(runner.clock())
    try:
      return await runner.sendHeartbeat(state)
    except CancelledError:
      return false
  of GatewayPayloadKind.HeartbeatAck:
    discard state.watchdog.heartbeatAcked(runner.clock())
    return true
  of GatewayPayloadKind.Reconnect:
    state.finish(ocResume)
    return false
  of GatewayPayloadKind.InvalidSession:
    if payload.invalidSession.resumable:
      state.finish(ocResume)
    else:
      runner.session.invalidate()
      state.finish(ocIdentify)
    return false
  of GatewayPayloadKind.Hello:
    # HELLO only belongs to handshake; a mid-stream HELLO is a protocol resync.
    state.finish(ocResume)
    return false
  of GatewayPayloadKind.Identify, GatewayPayloadKind.Resume,
      GatewayPayloadKind.Other:
    # Client-only or unknown opcodes from the server are ignored losslessly.
    return true

proc readerLoop(
    runner: GatewayShardRunner; state: ConnectionState) {.async: (raises: []).} =
  ## The single owner of receive, decode, and control-frame handling.
  while true:
    var event: GatewayTransportEvent
    try:
      event = await state.transport.receive()
    except CancelledError:
      return
    except CatchableError:
      state.finish(ocResume)
      return
    case event.kind
    of gatewayTransportClosed:
      runner.handleClose(state, event.closeInfo)
      return
    of gatewayMessageReceived:
      var decoded: Option[JsonNode]
      try:
        decoded = state.decoder.decode(event.message)
      except GatewayDecodeError:
        state.finish(ocResume)
        return
      if decoded.isNone:
        continue # a zlib-stream fragment; await more transport messages
      if not await runner.handlePayload(state, decoded.get):
        return

proc heartbeatLoop(
    runner: GatewayShardRunner; state: ConnectionState; intervalMs: int64) {.
    async: (raises: []).} =
  ## Periodic heartbeats plus zombie detection; never waits on user handlers.
  ##
  ## The first send is after interval * jitter, per the Gateway contract, and
  ## every send after that is one interval apart. Discord's rule is
  ## attempt-to-attempt: an ACK must arrive between two heartbeat sends. So before
  ## every periodic send, including the first. Any outstanding heartbeat
  ## (a prior periodic one or a server-requested OP1) means the last attempt was
  ## never acknowledged, and the connection is aborted with `ocResume` rather than
  ## sending a second heartbeat. Checking `hasOutstandingHeartbeat` instead of the
  ## deadline) is what makes this correct even when jitter puts the first attempt
  ## before an OP1 heartbeat's periodic deadline.
  var delay = clamp(runner.jitter(intervalMs), 0'i64, intervalMs)
  while true:
    if not await runner.sleepFor(delay):
      return
    if state.watchdog.hasOutstandingHeartbeat:
      state.finish(ocResume)
      return
    state.watchdog.periodicHeartbeatSent(runner.clock())
    try:
      if not await runner.sendHeartbeat(state):
        return
    except CancelledError:
      return
    delay = intervalMs

proc awaitHello(
    runner: GatewayShardRunner; state: ConnectionState): Future[Option[int64]] {.
    async: (raises: [CancelledError]).} =
  ## Waits for HELLO within the bounded timeout, honoring an early close/reconnect.
  ##
  ## Returns the heartbeat interval, or `none` after setting a connection outcome
  ## (timeout, close, RECONNECT, or a protocol violation before HELLO). Both raced
  ## futures are always cancelled and joined so none is left pending.
  let deadline = saturatingAddMs(runner.clock(), runner.config.helloTimeoutMs)
  while true:
    let remaining = deadline - runner.clock()
    if remaining <= 0:
      state.finish(ocResume)
      return none(int64)
    var recvFut: Future[GatewayTransportEvent]
    try:
      recvFut = state.transport.receive()
    except CatchableError:
      state.finish(ocResume)
      return none(int64)
    let timerFut = runner.sleeper(remaining)
    let abortFut = runner.abortEvent.wait()
    let raced = @[FutureBase(recvFut), FutureBase(timerFut), FutureBase(abortFut)]
    var winner: FutureBase
    try:
      winner = await race(FutureBase(recvFut), FutureBase(timerFut),
        FutureBase(abortFut))
    except CancelledError:
      await joinAll(raced)
      raise
    except CatchableError:
      await joinAll(raced)
      state.finish(ocResume)
      return none(int64)
    if winner == FutureBase(abortFut):
      # A watchdog fail-closed (for example a lost lease) aborted the run while we
      # were waiting for HELLO; stop and let the fatal reason terminate the run.
      await joinAll(raced)
      return none(int64)
    if winner != FutureBase(recvFut):
      # Timed out: cancel and join the receive, which aborts the connection.
      await joinAll(raced)
      state.finish(ocResume)
      return none(int64)
    # The receive won; cancel and join the timer and abort waiter, then read.
    await joinAll(@[FutureBase(timerFut), FutureBase(abortFut)])
    var event: GatewayTransportEvent
    try:
      event = await recvFut
    except CancelledError:
      raise
    except CatchableError:
      state.finish(ocResume)
      return none(int64)
    if event.kind == gatewayTransportClosed:
      runner.handleClose(state, event.closeInfo)
      return none(int64)
    var decoded: Option[JsonNode]
    try:
      decoded = state.decoder.decode(event.message)
    except GatewayDecodeError:
      state.finish(ocResume)
      return none(int64)
    if decoded.isNone:
      continue # fragmented HELLO; keep waiting within the same deadline
    var payload: GatewayPayload
    try:
      payload = decodeGatewayPayload(decoded.get)
    except CatchableError:
      state.finish(ocResume)
      return none(int64)
    case payload.kind
    of GatewayPayloadKind.Hello:
      return some(payload.hello.heartbeatIntervalMs)
    of GatewayPayloadKind.Reconnect:
      state.finish(ocResume)
      return none(int64)
    of GatewayPayloadKind.InvalidSession:
      if payload.invalidSession.resumable:
        state.finish(ocResume)
      else:
        runner.session.invalidate()
        state.finish(ocIdentify)
      return none(int64)
    else:
      # Anything other than HELLO first is a handshake violation.
      state.finish(ocResume)
      return none(int64)

proc sendResume(
    runner: GatewayShardRunner; state: ConnectionState): Future[bool] {.
    async: (raises: [CancelledError]).} =
  var text: string
  try:
    text = $initGatewayResume(
      runner.config.token, runner.session.resumeCursor).toJson()
  except CatchableError:
    state.finish(ocIdentify)
    return false
  return await runner.sendFrame(state, text)

proc sendIdentify(
    runner: GatewayShardRunner; state: ConnectionState): Future[bool] {.
    async: (raises: [CancelledError]).} =
  var text: string
  try:
    let shard = initGatewayShard(
      runner.config.shardId, runner.config.totalShards)
    text = $initGatewayIdentify(
      runner.config.token, runner.config.identifyProperties,
      runner.config.intents, shard = some(shard)).toJson()
  except CatchableError:
    runner.fail("identify payload build failed")
    state.finish(ocTerminal)
    return false
  return await runner.sendFrame(state, text)

proc reserveIdentify(runner: GatewayShardRunner): Future[bool] {.
    async: (raises: [CancelledError]).} =
  ## Reserves one non-refundable IDENTIFY permit, waiting out deferrals.
  ##
  ## Observes close/fatal so a shutdown during a deferral stops promptly, and
  ## floors the deferral wait so a zero retry hint cannot spin.
  while not runner.closing and not runner.fatal:
    let reserveFut = runner.coordination.reserveIdentify(runner.config.shardId)
    if not await runner.rpcOrAbort(FutureBase(reserveFut)):
      return false # aborted (a watchdog fail-closed or a close)
    var reservation: IdentifyReservation
    try:
      reservation = await reserveFut
    except CancelledError:
      raise
    except GatewayCoordinationError:
      runner.fail("coordination backend error on identify reserve")
      return false
    except CatchableError:
      runner.fail("identify reservation failed")
      return false
    case reservation.status
    of identifyReserved:
      return true
    of identifyDeferred:
      if not await runner.interruptibleSleep(
          max(reservation.retryAfterMs, minCoordinationRetryMs)):
        return false
  return false

proc teardownConnection(
    runner: GatewayShardRunner; state: ConnectionState) {.async: (raises: []).} =
  ## Cancels and joins the connection's tasks and releases its transport.
  if runner.activeConnScope != nil:
    await runner.activeConnScope.cancelAndJoin()
    runner.activeConnScope = nil
  if state.transport != nil and not state.transport.isClosed:
    state.transport.abort()
  runner.activeTransport = nil
  state.decoder.close()

proc runConnection(runner: GatewayShardRunner): Future[ConnectionOutcome] {.
    async: (raises: [CancelledError]).} =
  ## Runs one full connection attempt and returns what to do next.
  let resuming = runner.session.canResume
  var connectUrl: string
  if resuming:
    try:
      connectUrl = buildGatewayUrl(
        runner.session.resumeCursor.resumeGatewayUrl,
        runner.config.compression == gatewayCompressionZlibStream)
    except CatchableError:
      # A stored resume URL that no longer canonicalizes forces a fresh IDENTIFY.
      runner.session.invalidate()
      return ocIdentify
  else:
    connectUrl = runner.canonicalInitialUrl
    if not await runner.reserveIdentify():
      return ocTerminal # fatal already recorded

  # Ownership must still be locally valid before we connect on it.
  if not runner.leaseValid:
    runner.fail("lease expired before connect")
    return ocTerminal

  runner.lifecyclePhase = shardConnecting
  let driver = runner.transportFactory()
  let connectFut = connectGatewayTransport(connectUrl, driver)
  if not await runner.rpcOrAbort(FutureBase(connectFut)):
    # The abort and a successful connect can complete in the same scheduler
    # turn. rpcOrAbort prefers the abort in that case, but a completed future is
    # no longer cancellable, so reclaim the transport explicitly.
    if connectFut.completed:
      let abandonedTransport = connectFut.value
      if abandonedTransport != nil and not abandonedTransport.isClosed:
        abandonedTransport.abort()
    return ocTerminal # aborted (fail-closed) while connecting
  var transportConn: GatewayTransport
  try:
    transportConn = await connectFut
  except CancelledError:
    raise
  except CatchableError:
    return if resuming: ocResume else: ocIdentify
  runner.activeTransport = transportConn
  if not runner.leaseValid:
    transportConn.abort()
    runner.activeTransport = nil
    runner.fail("lease lost while connecting")
    return ocTerminal

  var decoder: GatewayMessageDecoder
  try:
    decoder = initGatewayMessageDecoder(runner.config.compression)
  except CatchableError:
    transportConn.abort()
    runner.activeTransport = nil
    runner.fail("decoder initialization failed")
    return ocTerminal
  let state = ConnectionState(
    transport: transportConn,
    decoder: move decoder,
    watchdog: initHeartbeatWatchdog(),
    done: newAsyncEvent(),
  )

  let interval = await runner.awaitHello(state)
  if interval.isNone:
    await runner.teardownConnection(state)
    return state.outcomeOr(if resuming: ocResume else: ocIdentify)

  try:
    state.watchdog.configureHeartbeat(interval.get, runner.clock())
  except ValueError:
    await runner.teardownConnection(state)
    return ocResume

  # Ownership must still be valid before we assert it via IDENTIFY/RESUME.
  if not runner.leaseValid:
    runner.fail("lease expired before handshake")
    await runner.teardownConnection(state)
    return ocTerminal

  let sendFut =
    if resuming: runner.sendResume(state)
    else: runner.sendIdentify(state)
  if not await runner.rpcOrAbort(FutureBase(sendFut)):
    await runner.teardownConnection(state)
    return ocTerminal # aborted (fail-closed) while sending the handshake
  var handshakeSent: bool
  try:
    handshakeSent = await sendFut
  except CancelledError:
    raise
  if not handshakeSent:
    await runner.teardownConnection(state)
    return state.outcomeOr(if resuming: ocResume else: ocIdentify)
  runner.lifecyclePhase = if resuming: shardResuming else: shardIdentifying

  runner.activeConnScope = newTaskScope()
  try:
    discard runner.activeConnScope.spawn(runner.readerLoop(state))
    discard runner.activeConnScope.spawn(
      runner.heartbeatLoop(state, interval.get))
  except ValueError:
    await runner.teardownConnection(state)
    return ocResume

  let doneFut = state.done.wait()
  let abortFut = runner.abortEvent.wait()
  try:
    try:
      discard await race(FutureBase(doneFut), FutureBase(abortFut))
    finally:
      await joinAll(@[FutureBase(doneFut), FutureBase(abortFut)])
  finally:
    await runner.teardownConnection(state)
  state.outcomeOr(ocResume)

proc acquireLease(runner: GatewayShardRunner): Future[bool] {.
    async: (raises: [CancelledError]).} =
  ## Acquires the shard's fenced lease, waiting out a currently-held shard.
  ##
  ## Never acquires after closure: a lease granted in a race with `close` is
  ## released immediately so the runner cannot own a shard past shutdown.
  while not runner.closing and not runner.fatal:
    var acquired: ShardAcquireResult
    try:
      acquired = await runner.coordination.acquireShard(runner.config.shardId)
    except CancelledError:
      raise
    except GatewayCoordinationError:
      runner.fail("coordination backend error on lease acquire")
      return false
    except CatchableError:
      runner.fail("lease acquire failed")
      return false
    if runner.closing or runner.fatal:
      if acquired.status == shardAcquired:
        try:
          discard await noCancel(
            runner.coordination.releaseShard(acquired.lease))
        except CatchableError:
          discard
      return false
    case acquired.status
    of shardAcquired:
      if not runner.recordLease(acquired.lease, runner.clock()):
        # A non-positive TTL cannot bound ownership: release and fail closed.
        try:
          discard await noCancel(
            runner.coordination.releaseShard(acquired.lease))
        except CatchableError:
          discard
        runner.fail("backend granted a non-positive lease ttl")
        return false
      return true
    of shardHeld:
      if not await runner.interruptibleSleep(
          max(acquired.retryAfterMs, minCoordinationRetryMs)):
        return false
  return false

proc loadSession(runner: GatewayShardRunner): Future[bool] {.
    async: (raises: [CancelledError]).} =
  ## Reads prior resume state under the lease, bounded by the lease expiry.
  ##
  ## A rejection fails closed; a read that cannot finish before the lease would
  ## expire also fails closed, so the runner never connects on an already-lapsed
  ## lease.
  if runner.closing or runner.fatal:
    return false
  let readFut = runner.coordination.readSession(runner.lease)
  var inTime: bool
  try:
    inTime = await runner.rpcBeforeDeadline(
      FutureBase(readFut), runner.leaseExpiryAtMs)
  except CancelledError:
    raise
  if not inTime:
    runner.fail("session read exceeded the lease expiry")
    return false
  var read: SessionReadResult
  try:
    read = await readFut
  except CancelledError:
    raise
  except GatewayCoordinationError:
    runner.fail("coordination backend error on session read")
    return false
  except CatchableError:
    runner.fail("session read failed")
    return false
  if runner.closing:
    return false
  case read.status
  of sessionReadRejected:
    runner.fail("session read rejected")
    return false
  of sessionRead:
    if read.state.isSome:
      runner.session = read.state.get
    return true

proc renewWatchdog(runner: GatewayShardRunner) {.async: (raises: []).} =
  ## Renews the lease before its backend-granted TTL expires, then checkpoints
  ## ownership. Fails closed the instant it cannot renew within the lease window.
  ##
  ## Renewal is scheduled from the lease's remaining TTL as well as the configured
  ## cadence. A TTL shorter than the cadence therefore still renews in time. The
  ## renew RPC is raced against the hard expiry deadline: if it cannot complete
  ## before the lease lapses, the run fails closed and the transport is aborted,
  ## so a superseded owner can never keep dispatching. The checkpoint is bounded
  ## separately so a slow write can never delay the next renew.
  while true:
    let now = runner.clock()
    let remaining = runner.leaseExpiryAtMs - now
    if remaining <= 0:
      runner.fail("lease expired before renewal")
      return
    # Renew at the configured cadence, but never later than half the remaining
    # TTL, leaving the other half to complete the renew RPC before expiry.
    let renewIn = clamp(
      min(runner.config.leaseRenewIntervalMs, remaining div 2), 1'i64, remaining)
    if not await runner.sleepFor(renewIn):
      return
    if runner.closing or runner.fatal:
      return

    let renewFut = runner.coordination.renewShard(runner.lease)
    var renewInTime: bool
    try:
      renewInTime = await runner.rpcBeforeDeadline(
        FutureBase(renewFut), runner.leaseExpiryAtMs)
    except CancelledError:
      return
    if not renewInTime:
      runner.fail("lease renewal exceeded the lease expiry")
      return
    var renew: LeaseRenewResult
    try:
      renew = await renewFut
    except CancelledError:
      return
    except GatewayCoordinationError:
      runner.fail("coordination backend error on lease renew")
      return
    except CatchableError:
      runner.fail("lease renew failed")
      return
    if renew.status == leaseLost:
      runner.fail("lease lost")
      return
    if not runner.recordLease(renew.lease, runner.clock()):
      runner.fail("backend granted a non-positive lease ttl on renew")
      return

    # Bound the ownership checkpoint by the earlier of a fraction of the cadence
    # and the lease expiry. A short renewed TTL therefore caps the write at
    # expiry. Rejection, failure, or timeout is ambiguous and fails closed.
    let writeFut = runner.coordination.writeSession(runner.lease, runner.session)
    let checkpointBudgetMs = max(1'i64, runner.config.leaseRenewIntervalMs div 4)
    let checkpointDeadline = min(
      runner.leaseExpiryAtMs, saturatingAddMs(runner.clock(), checkpointBudgetMs))
    var writeInTime: bool
    try:
      writeInTime = await runner.rpcBeforeDeadline(
        FutureBase(writeFut), checkpointDeadline)
    except CancelledError:
      return
    if not writeInTime:
      # A cancelled or timed-out checkpoint is ambiguous: the write may still land
      # late under this same fencing token and clobber a newer cursor. Fail closed
      # rather than continue and retry on the same lease.
      runner.fail("ownership checkpoint exceeded its bound")
      return
    var written: SessionWriteStatus
    try:
      written = await writeFut
    except CancelledError:
      return
    except GatewayCoordinationError:
      runner.fail("coordination backend error on ownership checkpoint")
      return
    except CatchableError:
      runner.fail("ownership checkpoint failed")
      return
    if written != sessionWritten:
      runner.fail("ownership checkpoint rejected")
      return

proc doShutdown(runner: GatewayShardRunner) {.async: (raises: []).} =
  ## The one-time teardown body; run uncancellably by `shutdown`.
  await runner.runScope.cancelAndJoin()
  if runner.activeConnScope != nil:
    await runner.activeConnScope.cancelAndJoin()
    runner.activeConnScope = nil
  if runner.activeTransport != nil:
    runner.activeTransport.abort()
    runner.activeTransport = nil
  await runner.dispatch.close()
  if runner.hasLease:
    runner.hasLease = false
    # Release the lease, but never block shutdown on it: bound the wait by a small
    # budget (capped at the remaining TTL) and, on timeout, cancel and join the
    # release. Backend TTL expiry frees the shard if the release never lands.
    let releaseFut = runner.coordination.releaseShard(runner.lease)
    let budgetMs = max(
      1'i64, min(runner.leaseExpiryAtMs - runner.clock(), shutdownReleaseBudgetMs))
    let timer = runner.sleeper(budgetMs)
    try:
      discard await noCancel(race(FutureBase(releaseFut), FutureBase(timer)))
    except CatchableError:
      discard
    await joinAll(@[FutureBase(releaseFut), FutureBase(timer)])
  runner.lifecyclePhase = shardStopped
  runner.shutdownComplete.fire()

proc shutdown(runner: GatewayShardRunner) {.async: (raises: []).} =
  ## Runs teardown exactly once; every caller awaits the same completion.
  ##
  ## The first caller drives teardown uncancellably, so even a cancelled `run`
  ## still cancels its tasks, aborts the transport, closes the dispatch runtime,
  ## and releases the lease. Concurrent `close` calls and the `run` finally all
  ## await the same completion rather than returning before teardown finishes.
  if not runner.shutdownStarted:
    runner.shutdownStarted = true
    await noCancel(runner.doShutdown())
  else:
    await noCancel(runner.shutdownComplete.wait())

proc runLoop(runner: GatewayShardRunner) {.
    async: (raises: [CancelledError, GatewayShardRunnerError]).} =
  ## The owned lifecycle body. Cancellation while closing is a graceful stop; a
  ## genuine external cancellation propagates. The finally always runs teardown.
  try:
    # The runner owns the dispatch runtime and starts it exactly once, before any
    # event is submitted, so a dispatch can never observe `dispatchNotStarted`.
    runner.dispatch.start()
    if not runner.interactionSink.isNil:
      # Interaction acknowledgement deadlines are independent of generic event
      # ordering. A dedicated bounded pool prevents one slow handler from aging
      # every later interaction while preserving runner-lifetime ownership.
      for _ in 0 ..< runner.interactionMaxConcurrent:
        try:
          discard runner.runScope.spawn(runner.runInteractionQueue())
        except ValueError:
          discard # the scope is fresh and only shutdown can close it here
    if not await runner.acquireLease():
      if runner.fatal and not runner.closing:
        raise newException(GatewayShardRunnerError, runner.fatalReason)
      return
    if not await runner.loadSession():
      if runner.fatal and not runner.closing:
        raise newException(GatewayShardRunnerError, runner.fatalReason)
      return
    try:
      discard runner.runScope.spawn(runner.renewWatchdog())
    except ValueError:
      discard # the scope is freshly created and not yet closed here

    while not runner.closing and not runner.fatal:
      let outcome = await runner.runConnection()
      if runner.closing or runner.fatal:
        break
      case outcome
      of ocTerminal:
        break # every terminal path also records a fatal reason, handled below
      of ocResume, ocIdentify:
        runner.lifecyclePhase = shardBackingOff
        if not await runner.interruptibleSleep(
            max(runner.config.reconnectBackoffMs, minReconnectBackoffMs)):
          break
    if runner.fatal and not runner.closing:
      runner.lifecyclePhase = shardTerminal
      raise newException(GatewayShardRunnerError, runner.fatalReason)
  except CancelledError:
    # Closing cancels this task (directly, or by aborting the transport). When we
    # initiated the close that is a graceful stop; only a genuine external
    # cancellation (not closing) is propagated.
    if not runner.closing:
      raise
  finally:
    await runner.shutdown()

proc start*(runner: GatewayShardRunner) {.raises: [GatewayShardRunnerError].} =
  ## Starts the shard's run loop as a single owned background task. One-shot.
  ##
  ## Raises `GatewayShardRunnerError` on a second start. A start after `close` is a
  ## no-op: the loop never runs and `close` owns teardown.
  if runner.started:
    raise newException(
      GatewayShardRunnerError, "gateway shard runner already started")
  runner.started = true
  if runner.closing:
    return
  runner.runTask = runLoop(runner)

proc join*(runner: GatewayShardRunner) {.
    async: (raises: [CancelledError, GatewayShardRunnerError]).} =
  ## Awaits the owned run task and re-raises its terminal failure, if any.
  ##
  ## Cancelling a joiner does not stop the shard and does not affect other
  ## joiners. The wait is detached from the run task. Use `close` to
  ## stop the shard. Returns immediately when the shard never started or was
  ## closed before starting.
  if runner.runTask.isNil:
    return
  if not runner.runTask.finished:
    let signal = newAsyncEvent()
    proc wake(arg: pointer) {.gcsafe, raises: [].} = signal.fire()
    runner.runTask.addCallback(wake)
    try:
      await signal.wait()
    finally:
      runner.runTask.removeCallback(wake)
  if runner.runTask.failed:
    var err: ref CatchableError
    try:
      err = runner.runTask.readError()
    except FutureError:
      err = nil
    # A `GatewayShardRunnerError` is the shard's terminal failure and is
    # re-raised; a `CancelledError` here is the run's own cancellation (e.g. from
    # `close`), not this joiner's, so it is a clean stop.
    if not err.isNil and err of GatewayShardRunnerError:
      raise (ref GatewayShardRunnerError)(err)

proc run*(runner: GatewayShardRunner) {.
    async: (raises: [CancelledError, GatewayShardRunnerError]).} =
  ## Starts the shard and joins it: `start` then `join`.
  ##
  ## Returns normally after `close`; raises `GatewayShardRunnerError` on a terminal
  ## failure. Cancelling `run` stops the join, not the shard; call `close` to stop
  ## the shard. At most one `start`/`run` succeeds.
  runner.start()
  await runner.join()

proc close*(runner: GatewayShardRunner) {.async: (raises: []).} =
  ## Requests shutdown, then cancels and joins the run task before returning.
  ##
  ## Cancelling the owned task unblocks a run parked on a coordination or connect
  ## future that is not otherwise raced, so `close` returns only after the run has
  ## fully exited and teardown has completed. Idempotent and join-safe.
  runner.closing = true
  runner.abortEvent.fire()
  if not runner.runTask.isNil and not runner.runTask.finished:
    runner.runTask.cancelSoon()
    try:
      await noCancel(runner.runTask)
    except CatchableError:
      discard # the run's own error surfaces through `run`, not `close`
  await runner.shutdown()
