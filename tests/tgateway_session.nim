import std/[assertions, options, sequtils]

import cordnim/gateway/[
  close_policy, dispatch, identify, session, sharding, supervisor]

block session_cursor_lifecycle:
  var state = initGatewaySession(ShardId(2))
  doAssert not state.canResume
  state.recordReady("session-a", "wss://gateway.discord.gg")
  doAssert state.observeSequence(GatewaySequence(10)) == sequenceAdvanced
  doAssert state.observeSequence(GatewaySequence(10)) == sequenceRepeated
  doAssert state.observeSequence(GatewaySequence(9)) == sequenceRegressed
  doAssert state.observeSequence(GatewaySequence(11)) == sequenceAdvanced
  doAssert state.resumeCursor.sequence.toInt64 == 11
  state.invalidate()
  doAssert not state.canResume
  doAssertRaises ValueError:
    discard state.resumeCursor

block memory_session_store:
  var store = initMemorySessionStore()
  var state = initGatewaySession(ShardId(1))
  state.recordReady("session-b", "wss://gateway.discord.gg")
  discard state.observeSequence(GatewaySequence(4))
  store.put(state)
  doAssert store.len == 1
  doAssert store.contains(ShardId(1))
  doAssert store.get(ShardId(1)).get.canResume
  store.del(ShardId(1))
  doAssert store.get(ShardId(1)).isNone

block close_code_policy:
  doAssert(
    classifyGatewayClose(GatewayCloseCode(4007)).action == identifyNewSession
  )
  doAssert classifyGatewayClose(GatewayCloseCode(4009)).retryable
  doAssert(
    classifyGatewayClose(GatewayCloseCode(4014)).action == stopReconnecting
  )
  doAssert classifyGatewayClose(GatewayCloseCode(1006)).action == resumeSession

block identify_buckets_and_budget:
  var coordinator = initIdentifyCoordinator(
    SessionStartLimit(
      total: 2,
      remaining: 2,
      resetAfterMs: 60_000,
      maxConcurrency: 2,
    ),
    nowMs = 100,
  )
  let first = coordinator.tryAcquire(ShardId(0), 100)
  doAssert first.kind == identifyAcquired
  doAssert first.lease.bucket == 0

  let cooling = coordinator.tryAcquire(ShardId(2), 101)
  doAssert cooling.kind == identifyBucketCoolingDown
  doAssert cooling.retryAtMs == 5_100

  let second = coordinator.tryAcquire(ShardId(1), 101)
  doAssert second.kind == identifyAcquired
  doAssert coordinator.remaining == 0

  let exhausted = coordinator.tryAcquire(ShardId(3), 5_101)
  doAssert exhausted.kind == identifyBudgetExhausted
  doAssert exhausted.retryAtMs == 60_100

  let reset = coordinator.tryAcquire(ShardId(0), 60_100)
  doAssert reset.kind == identifyAcquired
  doAssert coordinator.remaining == 1

block shard_partitioning:
  let p0 = planShards(10, 0, 3)
  let p1 = planShards(10, 1, 3)
  let p2 = planShards(10, 2, 3)
  doAssert p0.owned.len == 4
  doAssert p1.owned.len == 3
  doAssert p2.owned.len == 3
  doAssert toSeq(p0.shardIds).mapIt(it.toUint16) == @[0'u16, 1, 2, 3]
  doAssert toSeq(p2.shardIds).mapIt(it.toUint16) == @[7'u16, 8, 9]

block bounded_dispatch:
  var queue = initBoundedQueue[string](2)
  doAssert queue.tryAdd("first")
  doAssert queue.tryAdd("second")
  doAssert not queue.tryAdd("overflow")
  doAssert queue.isFull
  doAssert queue.popFirst.get == "first"

  var ordered = initDispatchLaneChooser(orderedPolicy(4))
  doAssert ordered.chooseLane(99) == 0

  var concurrent = initDispatchLaneChooser(concurrentPolicy(4, 2))
  doAssert concurrent.chooseLane(0) == 0
  doAssert concurrent.chooseLane(0) == 1
  doAssert concurrent.chooseLane(0) == 0

  var partitioned = initDispatchLaneChooser(partitionedPolicy(4, 4))
  doAssert partitioned.chooseLane(9) == 1
  doAssert partitioned.chooseLane(9) == 1

block supervised_reconnect_and_heartbeat:
  var supervisor = initGatewaySupervisor(planShards(2, 0, 1))
  doAssert supervisor.len == 2
  doAssert supervisor.contains(ShardId(0))
  doAssert supervisor.get(ShardId(1)).isSome
  doAssert supervisor.get(ShardId(3)).isNone
  var shard = supervisor.shard(ShardId(0))
  # Heartbeat timing is unknown until HELLO arrives on the connection.
  doAssert not shard.heartbeat.isConfigured
  shard.beginConnect()
  shard.beginIdentify()
  shard.configureHeartbeat(1_000, 0) # HELLO installs the interval
  doAssert shard.heartbeat.isConfigured
  shard.ready("session", "wss://gateway.discord.gg")
  discard shard.session.observeSequence(GatewaySequence(12))
  shard.heartbeat.periodicHeartbeatSent(100)
  doAssert not shard.heartbeat.heartbeatTimedOut(1_099)
  doAssert shard.heartbeat.heartbeatTimedOut(1_100)
  doAssert shard.heartbeat.heartbeatAcked(1_101)
  doAssert shard.heartbeat.lastRttMs.get == 1_001
  let resume = shard.disconnected(GatewayCloseCode(4000))
  doAssert resume.action == resumeSession
  doAssert shard.lifecycle == shardResuming
  # Reconnect resets heartbeat timing; the next HELLO reconfigures it.
  doAssert not shard.heartbeat.isConfigured
  let fatal = shard.disconnected(GatewayCloseCode(4014))
  doAssert fatal.terminal
  doAssert shard.lifecycle == shardTerminal

block ready_clears_prior_session_epoch_sequence:
  var state = initGatewaySession(ShardId(5))
  state.recordReady("old-session", "wss://old")
  discard state.observeSequence(GatewaySequence(500))
  doAssert state.canResume
  doAssert state.resumeCursor.sequence.toInt64 == 500
  # A brand-new READY opens a new session; the old sequence must not leak in.
  state.recordReady("new-session", "wss://new")
  doAssert not state.canResume # cursor cleared, awaits a fresh dispatch
  doAssert state.sequence.isNone
  doAssert state.sessionId == "new-session"
  # The first dispatch of the new session starts a fresh cursor, not one forced
  # above the previous session's 500.
  doAssert state.observeSequence(GatewaySequence(3)) == sequenceAdvanced
  doAssert state.resumeCursor.sequence.toInt64 == 3

block heartbeat_unconfigured_watchdog_is_inert:
  var w = initHeartbeatWatchdog()
  doAssert not w.isConfigured
  doAssert w.heartbeatIntervalMs.isNone
  doAssert not w.periodicHeartbeatDue(1_000_000)
  w.periodicHeartbeatSent(5) # no-op while unconfigured
  w.serverHeartbeatSent(6) # no-op while unconfigured
  doAssert not w.hasOutstandingHeartbeat
  doAssert not w.heartbeatTimedOut(1_000_000)
  doAssert not w.heartbeatAcked(7)
  doAssertRaises ValueError:
    w.configureHeartbeat(0, 0) # a non-positive interval is rejected

block heartbeat_periodic_schedule_and_ack:
  var w = initHeartbeatWatchdog()
  w.configureHeartbeat(1_000, 0) # first periodic due at 1_000
  doAssert w.heartbeatIntervalMs.get == 1_000
  doAssert not w.periodicHeartbeatDue(999)
  doAssert w.periodicHeartbeatDue(1_000)
  w.periodicHeartbeatSent(1_000) # deadline 2_000, next due 2_000
  doAssert w.hasOutstandingHeartbeat
  doAssert w.heartbeatAcked(1_400) # acked before the deadline
  doAssert not w.hasOutstandingHeartbeat
  doAssert w.lastRttMs.get == 400
  doAssert not w.heartbeatTimedOut(2_000) # nothing outstanding
  doAssert w.periodicHeartbeatDue(2_000)

block heartbeat_immediate_send_does_not_shift_periodic_deadline:
  # A server-requested heartbeat before the tick must not extend the window
  # in which a missing ACK for the outstanding periodic heartbeat is tolerated.
  var w = initHeartbeatWatchdog()
  w.configureHeartbeat(1_000, 0)
  w.periodicHeartbeatSent(0) # deadline 1_000
  w.serverHeartbeatSent(990) # must NOT move the deadline out to 1_990
  doAssert not w.heartbeatTimedOut(999)
  doAssert w.heartbeatTimedOut(1_000) # abort fires at the periodic deadline

block heartbeat_later_periodic_cannot_overwrite_unacked:
  # Even a later periodic send while the previous one is unacked must still force
  # a timeout: the outstanding deadline cannot be pushed forward to hide it.
  var w = initHeartbeatWatchdog()
  w.configureHeartbeat(1_000, 0)
  w.periodicHeartbeatSent(0) # deadline 1_000, never acked
  w.periodicHeartbeatSent(1_000) # schedule advances, but deadline stays 1_000
  doAssert w.heartbeatTimedOut(1_000)

block heartbeat_schedule_saturates_on_huge_interval:
  # A pathological interval must clamp the periodic due time and the abort
  # deadline to int64.high rather than wrap them into the past.
  var w = initHeartbeatWatchdog()
  w.configureHeartbeat(high(int64), 1_000)
  doAssert w.isConfigured
  doAssert not w.periodicHeartbeatDue(high(int64) - 1)
  doAssert w.periodicHeartbeatDue(high(int64))
  w.periodicHeartbeatSent(1_000) # deadline saturates to high(int64)
  doAssert not w.heartbeatTimedOut(high(int64) - 1)
  doAssert w.heartbeatTimedOut(high(int64))

block heartbeat_server_request_inherits_periodic_deadline:
  # An immediate heartbeat with nothing outstanding is bounded by the next
  # periodic deadline, and its ACK leaves the periodic schedule untouched.
  var w = initHeartbeatWatchdog()
  w.configureHeartbeat(1_000, 0) # first periodic due at 1_000
  w.serverHeartbeatSent(200) # outstanding, deadline = 1_000
  doAssert w.hasOutstandingHeartbeat
  doAssert not w.heartbeatTimedOut(999)
  doAssert w.heartbeatTimedOut(1_000)
  doAssert w.heartbeatAcked(1_000) # a late ACK still clears and records RTT
  doAssert w.lastRttMs.get == 800
  doAssert w.periodicHeartbeatDue(1_000)
