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
  var supervisor = initGatewaySupervisor(planShards(2, 0, 1), 1_000)
  doAssert supervisor.len == 2
  doAssert supervisor.contains(ShardId(0))
  doAssert supervisor.get(ShardId(1)).isSome
  doAssert supervisor.get(ShardId(3)).isNone
  var shard = supervisor.shard(ShardId(0))
  shard.beginConnect()
  shard.beginIdentify()
  shard.ready("session", "wss://gateway.discord.gg")
  discard shard.session.observeSequence(GatewaySequence(12))
  shard.heartbeat.heartbeatSent(100)
  doAssert not shard.heartbeat.heartbeatTimedOut(1_099)
  doAssert shard.heartbeat.heartbeatTimedOut(1_100)
  doAssert shard.heartbeat.heartbeatAcked(1_101)
  doAssert shard.heartbeat.lastRttMs.get == 1_001
  let resume = shard.disconnected(GatewayCloseCode(4000))
  doAssert resume.action == resumeSession
  doAssert shard.lifecycle == shardResuming
  let fatal = shard.disconnected(GatewayCloseCode(4014))
  doAssert fatal.terminal
  doAssert shard.lifecycle == shardTerminal
