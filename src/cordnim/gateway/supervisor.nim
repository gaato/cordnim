## Pure state machines used by a supervised Gateway shard runtime.
##
## Lifecycle mutation procedures are transport commands, not transition
## validators. The supervising transport owns legal call ordering.

import std/options

import ./[close_policy, session, sharding]

type
  ShardLifecycle* = enum ## Observable lifecycle phase for one Gateway shard.
    shardStopped, ## No connection task is active.
    shardConnecting, ## A WebSocket connection is being established.
    shardIdentifying, ## The shard is starting a new Discord session.
    shardReady, ## READY was accepted and events may be dispatched.
    shardResuming, ## The shard is reconnecting with a retained cursor.
    shardBackingOff, ## A new IDENTIFY is pending scheduler permission.
    shardTerminal ## Reconnect requires configuration or operator action.

  HeartbeatOutstanding = object ## One unacknowledged heartbeat awaiting an ACK.
    generation: uint64 ## Generation id of the oldest unacknowledged send.
    sentAtMs: int64 ## When it was transmitted, used to measure the ACK RTT.
    deadlineMs: int64 ## Periodic deadline by which an ACK must arrive.

  HeartbeatWatchdog* = object ## Heartbeat timing independent of user handlers.
    ##
    ## The interval is unknown until HELLO, so a fresh watchdog is *unconfigured*
    ## and inert; `configureHeartbeat` installs the interval and starts the
    ## periodic schedule, and reconnecting returns it to the unconfigured state.
    ## Once configured it keeps the periodic schedule (advanced only by periodic
    ## sends) separate from an outstanding heartbeat's abort deadline (fixed at
    ## the oldest unacknowledged send), so neither a server-requested heartbeat
    ## nor a later periodic send can hide a missing ACK. State is read through
    ## the accessors below; the timing fields are private to preserve that
    ## invariant.
    interval: Option[int64] ## HELLO heartbeat interval; `none` until configured.
    generation: uint64 ## Count of heartbeats sent since the last configure.
    outstanding: Option[HeartbeatOutstanding] ## Oldest unacked heartbeat, if any.
    periodicDueAtMs: int64 ## Next periodic send time; valid while configured.
    lastAckAtMs: Option[int64] ## Timestamp of the latest accepted ACK.
    lastRttMs: Option[int64] ## Round-trip duration of the latest accepted ACK.

  ShardRuntime* = object ## Supervisory state for one owned Gateway shard.
    shardId*: ShardId ## Shard represented by this runtime.
    lifecycle*: ShardLifecycle ## Current connection lifecycle phase.
    reconnectAttempts*: uint32 ## Consecutive disconnect count since READY.
    session*: GatewaySessionState ## Resume credentials and sequence cursor.
    heartbeat*: HeartbeatWatchdog ## Heartbeat timing state.

  ReconnectPlan* = object ## Action emitted when a shard disconnects.
    action*: ReconnectAction ## Resume, identify, or stop decision.
    attempt*: uint32 ## Consecutive reconnect attempt number.
    terminal*: bool ## Whether automatic reconnect must stop.

  GatewaySupervisor* = object ## Shard runtimes owned by one process.
    shards: seq[ShardRuntime]

func saturatingAddMs(base, delta: int64): int64 {.raises: [].} =
  ## Adds a duration to a timestamp, clamping at the `int64` bounds instead of
  ## wrapping, so a far-future interval cannot fold a deadline into the past.
  if delta > 0 and base > high(int64) - delta:
    high(int64)
  elif delta < 0 and base < low(int64) - delta:
    low(int64)
  else:
    base + delta

func initHeartbeatWatchdog*(): HeartbeatWatchdog {.raises: [].} =
  ## Creates an unconfigured watchdog; the interval arrives with HELLO.
  HeartbeatWatchdog()

func isConfigured*(watchdog: HeartbeatWatchdog): bool {.inline, raises: [].} =
  ## Reports whether a HELLO heartbeat interval has been installed.
  watchdog.interval.isSome

func heartbeatIntervalMs*(watchdog: HeartbeatWatchdog): Option[int64] {.
    inline, raises: [].} =
  ## Returns the configured heartbeat interval, or `none` before HELLO.
  watchdog.interval

func lastAckAtMs*(watchdog: HeartbeatWatchdog): Option[int64] {.
    inline, raises: [].} =
  ## Returns the timestamp of the latest accepted ACK, if any.
  watchdog.lastAckAtMs

func lastRttMs*(watchdog: HeartbeatWatchdog): Option[int64] {.
    inline, raises: [].} =
  ## Returns the round-trip duration of the latest accepted ACK, if any.
  watchdog.lastRttMs

func hasOutstandingHeartbeat*(watchdog: HeartbeatWatchdog): bool {.
    inline, raises: [].} =
  ## Reports whether a sent heartbeat is still awaiting its ACK.
  watchdog.outstanding.isSome

proc configureHeartbeat*(
    watchdog: var HeartbeatWatchdog;
    intervalMs, nowMs: int64,
) {.raises: [ValueError].} =
  ## Installs the HELLO heartbeat interval and starts the periodic schedule.
  ##
  ## Any prior timing state is discarded, so calling this on a reconnect's HELLO
  ## restarts scheduling from a clean slate. Rejects a non-positive interval.
  if intervalMs <= 0:
    raise newException(
      ValueError, "heartbeat interval must be greater than zero")
  watchdog = HeartbeatWatchdog(
    interval: some(intervalMs),
    periodicDueAtMs: saturatingAddMs(nowMs, intervalMs),
  )

func periodicHeartbeatDue*(
    watchdog: HeartbeatWatchdog; nowMs: int64): bool {.raises: [].} =
  ## Tests whether a scheduled periodic heartbeat is due to be sent now.
  watchdog.interval.isSome and nowMs >= watchdog.periodicDueAtMs

proc periodicHeartbeatSent*(
    watchdog: var HeartbeatWatchdog; nowMs: int64) {.raises: [].} =
  ## Records a scheduled periodic heartbeat send and advances the schedule.
  ##
  ## The periodic due time always moves forward by one interval. A still
  ## outstanding heartbeat keeps its original deadline: a later periodic send
  ## must never extend the window in which a missing ACK is tolerated. Inert
  ## while the watchdog is unconfigured.
  if watchdog.interval.isNone:
    return
  let interval = watchdog.interval.get
  inc watchdog.generation
  let nextDue = saturatingAddMs(nowMs, interval)
  watchdog.periodicDueAtMs = nextDue
  if watchdog.outstanding.isNone:
    watchdog.outstanding = some(HeartbeatOutstanding(
      generation: watchdog.generation,
      sentAtMs: nowMs,
      deadlineMs: nextDue,
    ))

proc serverHeartbeatSent*(
    watchdog: var HeartbeatWatchdog; nowMs: int64) {.raises: [].} =
  ## Records an immediate OP1 heartbeat sent at the server's request.
  ##
  ## It never advances the periodic schedule and never replaces an existing
  ## outstanding heartbeat, so it cannot postpone a periodic abort deadline. When
  ## nothing is outstanding it inherits the next periodic deadline, keeping the
  ## abort bound anchored to the periodic schedule. Inert while unconfigured.
  if watchdog.interval.isNone:
    return
  inc watchdog.generation
  if watchdog.outstanding.isNone:
    watchdog.outstanding = some(HeartbeatOutstanding(
      generation: watchdog.generation,
      sentAtMs: nowMs,
      deadlineMs: watchdog.periodicDueAtMs,
    ))

proc heartbeatAcked*(
    watchdog: var HeartbeatWatchdog; nowMs: int64): bool {.raises: [].} =
  ## Records an ACK for the outstanding heartbeat and its round-trip duration.
  ##
  ## Returns false when no heartbeat is outstanding or the ACK predates the send,
  ## leaving the outstanding state untouched so an impossible ACK cannot clear a
  ## real timeout.
  if watchdog.outstanding.isNone:
    return false
  let pending = watchdog.outstanding.get
  if nowMs < pending.sentAtMs:
    return false
  watchdog.outstanding = none(HeartbeatOutstanding)
  watchdog.lastAckAtMs = some(nowMs)
  watchdog.lastRttMs = some(nowMs - pending.sentAtMs)
  true

func heartbeatTimedOut*(
    watchdog: HeartbeatWatchdog; nowMs: int64): bool {.raises: [].} =
  ## Tests whether the outstanding heartbeat missed its periodic ACK deadline.
  watchdog.outstanding.isSome and nowMs >= watchdog.outstanding.get.deadlineMs

proc initShardRuntime*(shardId: ShardId): ShardRuntime {.raises: [].} =
  ## Creates stopped runtime state for one shard, heartbeat unconfigured.
  ShardRuntime(
    shardId: shardId,
    session: initGatewaySession(shardId),
    heartbeat: initHeartbeatWatchdog(),
  )

proc configureHeartbeat*(
    runtime: var ShardRuntime; intervalMs, nowMs: int64) {.
    raises: [ValueError].} =
  ## Installs the HELLO heartbeat interval on this shard's watchdog.
  runtime.heartbeat.configureHeartbeat(intervalMs, nowMs)

proc beginConnect*(runtime: var ShardRuntime) {.raises: [].} =
  ## Marks the shard as establishing its transport.
  runtime.lifecycle = shardConnecting

proc beginIdentify*(runtime: var ShardRuntime) {.raises: [].} =
  ## Marks the shard as sending a new-session IDENTIFY.
  runtime.lifecycle = shardIdentifying

proc ready*(
    runtime: var ShardRuntime;
    sessionId, resumeGatewayUrl: sink string,
) =
  ## Records READY session data and clears the reconnect counter.
  runtime.session.recordReady(sessionId, resumeGatewayUrl)
  runtime.lifecycle = shardReady
  runtime.reconnectAttempts = 0

proc disconnected*(
    runtime: var ShardRuntime;
    closeCode: GatewayCloseCode,
): ReconnectPlan {.raises: [].} =
  ## Applies close-code policy and advances the shard reconnect state.
  var decision = classifyGatewayClose(closeCode)
  # A resumable close code cannot synthesize missing credentials. Falling back
  # to IDENTIFY keeps the emitted plan executable by the transport layer.
  if decision.action == resumeSession and not runtime.session.canResume:
    decision.action = identifyNewSession

  # The transport is gone: any pending heartbeat schedule is stale, and a new
  # HELLO on the next connection reconfigures it. Reset to unconfigured so a
  # heartbeat cannot fire against a dead connection's timing.
  runtime.heartbeat = initHeartbeatWatchdog()

  runtime.reconnectAttempts.inc
  case decision.action
  of resumeSession:
    runtime.lifecycle = shardResuming
  of identifyNewSession:
    runtime.session.invalidate()
    runtime.lifecycle = shardBackingOff
  of stopReconnecting:
    runtime.lifecycle = shardTerminal

  ReconnectPlan(
    action: decision.action,
    attempt: runtime.reconnectAttempts,
    terminal: decision.action == stopReconnecting,
  )

proc initGatewaySupervisor*(plan: ShardPlan): GatewaySupervisor {.raises: [].} =
  ## Creates one stopped runtime for every shard assigned by `plan`.
  ##
  ## Heartbeat timing is left unconfigured on each shard until its HELLO arrives.
  for shardId in plan.shardIds:
    result.shards.add(initShardRuntime(shardId))

func len*(supervisor: GatewaySupervisor): int {.inline, raises: [].} =
  ## Returns the number of shards owned by the supervisor.
  supervisor.shards.len

func contains*(supervisor: GatewaySupervisor; shardId: ShardId): bool {.
    raises: [].} =
  ## Tests whether the supervisor owns `shardId`.
  for value in supervisor.shards:
    if value.shardId == shardId:
      return true
  false

func get*(
    supervisor: GatewaySupervisor;
    shardId: ShardId,
): Option[ShardRuntime] {.raises: [].} =
  ## Returns a copy of runtime state, or `none` for an unowned shard.
  for value in supervisor.shards:
    if value.shardId == shardId:
      return some(value)
  none(ShardRuntime)

iterator items*(supervisor: GatewaySupervisor): ShardRuntime =
  ## Yields copies of every owned shard runtime.
  for shard in supervisor.shards:
    yield shard

proc shard*(
    supervisor: var GatewaySupervisor;
    shardId: ShardId,
): var ShardRuntime =
  ## Returns mutable runtime state or raises `KeyError` for an unowned shard.
  for value in supervisor.shards.mitems:
    if value.shardId == shardId:
      return value
  raise newException(KeyError, "shard is not owned by this supervisor")
