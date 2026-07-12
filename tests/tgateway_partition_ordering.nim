## Regression tests for guild-aware dispatch partitioning.
##
## Guild lifecycle events (GUILD_CREATE/UPDATE/DELETE) identify the guild in
## `d.id`; every other guild-scoped event uses `d.guild_id`. Keying on the right
## field keeps all events for one guild on one partition lane, so a later
## GUILD_CREATE cannot be reordered ahead of an earlier update to the same guild's
## cached state.

import std/json

import chronos

import cordnim/gateway/[dispatch, dispatch_runtime, session, shard_runner]

block partition_key_uses_guild_identity_by_event:
  # Lifecycle events use d.id; other guild-scoped events use d.guild_id; the same
  # guild always yields the same key.
  doAssert gatewayPartitionKey("GUILD_CREATE", %*{"id": "42"}) == 42'u64
  doAssert gatewayPartitionKey("GUILD_UPDATE", %*{"id": "42"}) == 42'u64
  doAssert gatewayPartitionKey("GUILD_DELETE", %*{"id": "42"}) == 42'u64
  doAssert gatewayPartitionKey("MESSAGE_CREATE", %*{"guild_id": "42"}) == 42'u64
  doAssert gatewayPartitionKey("GUILD_MEMBER_ADD", %*{"guild_id": "42"}) == 42'u64
  doAssert gatewayPartitionKey("THREAD_CREATE", %*{"guild_id": "42"}) == 42'u64
  # All of the above share one partition key -> one lane.
  let key = gatewayPartitionKey("GUILD_CREATE", %*{"id": "42"})
  doAssert gatewayPartitionKey("MESSAGE_CREATE", %*{"guild_id": "42"}) == key
  # Different guilds differ.
  doAssert gatewayPartitionKey("GUILD_CREATE", %*{"id": "7"}) != key
  # No guild scope, or a malformed id the cache will reject, collapses to 0.
  doAssert gatewayPartitionKey("READY", %*{"session_id": "abc"}) == 0'u64
  doAssert gatewayPartitionKey("GUILD_CREATE", %*{"id": "not-a-number"}) == 0'u64
  doAssert gatewayPartitionKey("MESSAGE_CREATE", %*{}) == 0'u64

block same_guild_events_share_a_lane:
  # Under a partitioned policy, GUILD_CREATE (d.id) and a member event (d.guild_id)
  # for one guild map to the same lane; a different guild maps elsewhere.
  var chooser = initDispatchLaneChooser(partitionedPolicy(16, 8))
  let laneCreate = chooser.chooseLane(gatewayPartitionKey("GUILD_CREATE", %*{"id": "42"}))
  let laneMember = chooser.chooseLane(gatewayPartitionKey("GUILD_MEMBER_ADD", %*{"guild_id": "42"}))
  doAssert laneCreate == laneMember

type Probe = ref object
  order: seq[string]
  target: int
  reached: AsyncEvent
  gate: AsyncEvent

proc newProbe(): Probe = Probe(reached: newAsyncEvent(), gate: newAsyncEvent())

proc handler(probe: Probe): GatewayDispatchHandler =
  result = proc(event: DispatchEvent): Future[void] {.async.} =
    await probe.gate.wait() # hold the lane until released
    probe.order.add event.name
    if probe.order.len >= probe.target:
      probe.reached.fire()

proc ev(name: string; seqNo: int; data: JsonNode): DispatchEvent =
  initDispatchEvent(
    name, ShardId(0), GatewaySequence(seqNo), gatewayPartitionKey(name, data),
    $data)

block guild_lifecycle_cannot_reorder_ahead_of_updates:
  # With the lane blocked, submit CREATE, UPDATE, then a member event for one
  # guild. Because they share a lane, they drain in submission order, so a later
  # GUILD_CREATE cannot overtake an earlier update.
  let probe = newProbe()
  probe.target = 3
  let rt = newGatewayDispatchRuntime(partitionedPolicy(16, 8), handler(probe))
  rt.start()
  doAssert rt.submit(ev("GUILD_CREATE", 1, %*{"id": "42"})) == dispatchAccepted
  doAssert rt.submit(ev("GUILD_UPDATE", 2, %*{"id": "42"})) == dispatchAccepted
  doAssert rt.submit(ev("GUILD_MEMBER_ADD", 3, %*{"guild_id": "42"})) == dispatchAccepted
  doAssert probe.order.len == 0 # nothing processed while the lane is blocked
  probe.gate.fire()
  waitFor probe.reached.wait()
  doAssert probe.order == @["GUILD_CREATE", "GUILD_UPDATE", "GUILD_MEMBER_ADD"]
  waitFor rt.close()

echo "tgateway_partition_ordering: all blocks passed"
