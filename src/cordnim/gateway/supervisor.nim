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

  HeartbeatWatchdog* = object ## Heartbeat timing independent of user handlers.
    intervalMs*: int64 ## Server-provided heartbeat interval.
    lastSentAtMs*: Option[int64] ## Monotonic timestamp of the latest heartbeat.
    lastAckAtMs*: Option[int64] ## Monotonic timestamp of the latest valid ACK.
    lastRttMs*: Option[int64] ## Round-trip duration of the latest valid ACK.

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

proc initHeartbeatWatchdog*(intervalMs: int64): HeartbeatWatchdog =
  ## Creates a watchdog and rejects a non-positive heartbeat interval.
  if intervalMs <= 0:
    raise newException(
      ValueError,
      "heartbeat interval must be greater than zero",
    )
  HeartbeatWatchdog(intervalMs: intervalMs)

proc heartbeatSent*(watchdog: var HeartbeatWatchdog; nowMs: int64) {.
    raises: [].} =
  ## Records transmission of a heartbeat at a monotonic timestamp.
  ##
  ## The caller must check `heartbeatTimedOut` before recording a later send;
  ## only the latest transmission time is retained.
  # Only the latest send is retained. The supervising loop must check timeout
  # state before recording a later heartbeat, or it can hide an unacknowledged
  # earlier send.
  watchdog.lastSentAtMs = some(nowMs)

proc heartbeatAcked*(watchdog: var HeartbeatWatchdog; nowMs: int64): bool {.
    raises: [].} =
  ## Records a valid ACK and RTT, returning false for impossible timestamps.
  if watchdog.lastSentAtMs.isNone or nowMs < watchdog.lastSentAtMs.get:
    return false
  watchdog.lastAckAtMs = some(nowMs)
  watchdog.lastRttMs = some(nowMs - watchdog.lastSentAtMs.get)
  true

func heartbeatTimedOut*(watchdog: HeartbeatWatchdog; nowMs: int64): bool {.
    raises: [].} =
  ## Tests whether the latest heartbeat lacked an ACK for one interval.
  if watchdog.lastSentAtMs.isNone:
    return false
  let sentAt = watchdog.lastSentAtMs.get
  let unacknowledged = watchdog.lastAckAtMs.isNone or
    watchdog.lastAckAtMs.get < sentAt
  unacknowledged and nowMs - sentAt >= watchdog.intervalMs

proc initShardRuntime*(
    shardId: ShardId;
    heartbeatIntervalMs: int64,
): ShardRuntime =
  ## Creates stopped runtime state for one shard.
  ShardRuntime(
    shardId: shardId,
    session: initGatewaySession(shardId),
    heartbeat: initHeartbeatWatchdog(heartbeatIntervalMs),
  )

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

proc initGatewaySupervisor*(
    plan: ShardPlan;
    heartbeatIntervalMs: int64,
): GatewaySupervisor =
  ## Creates one stopped runtime for every shard assigned by `plan`.
  for shardId in plan.shardIds:
    result.shards.add(initShardRuntime(shardId, heartbeatIntervalMs))

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
