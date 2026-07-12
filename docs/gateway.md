# Gateway runtime

Cordnim's Gateway layer owns connection and shard mechanics while leaving event
policy and application handlers injectable. HTTP-only interaction applications
do not need it.

## Application API

Most applications should import `cordnim/bot`. The high-level runtime owns the
authenticated REST client, `/gateway/bot` lookup, local shard coordination,
Chronos WebSockets, interaction dispatcher, and typed event router. Construction
does no network I/O. `app.run()` starts and closes the complete component.

```nim
import std/os

import chronos
import cordnim
import cordnim/bot

let app = newDiscordApp(
  services,
  initAppConfig(
    ingressGateway,
    gatewaySubscriptions({giGuildMessages, giMessageContent})
  ),
  commands
)

let bot = newGatewayBotRuntime(
  app,
  initSecret[BotToken](getEnv("DISCORD_BOT_TOKEN")),
  singleProcessGateway()
)

bot.events.onMessageCreate proc(
    ctx: GatewayEventContext[Services]; message: Message
): Future[void] {.async.} =
  await recordMessage(ctx.services, message)

waitFor app.run()
```

`bot.interactions` exposes the shared command, component, modal, and
autocomplete dispatcher when the application uses Gateway interaction ingress.
`bot.rest` exposes the owned semantic REST client during application handlers.
The shard runner intercepts `INTERACTION_CREATE` before the generic event queue,
so interaction acknowledgement work keeps its independent concurrency bound.

Typed registrations cover every semantic event decoded by
`cordnim/gateway/events`. A handler receives its event payload and a
`GatewayEventContext[S]` with app services, shard, sequence, partition, and
receive time. `onUnhandled` receives decoded but unregistered events.
`onUnknown` receives future Discord event names through `UnknownGatewayEvent`.
Duplicate registration raises `ValueError` instead of replacing a handler.

Choose coordination at construction. `singleProcessGateway()` uses the
in-memory fenced adapter and rejects `processCount > 1`.
`externalGateway(coordination)` accepts a caller-supplied distributed backend.
`initGatewayBotOptions` exposes shard selection, bounded event policy, restart
budget, tuning, transport limits, observers, and injectable production
dependencies. Tests may inject `gatewayBotInfo`, clock, sleeper, jitter, and a
Gateway transport factory without opening Discord connections.

## Assembly boundary

The lower-level assembly API remains available for custom runtimes. A deployment
using it supplies these inputs:

- the initial Gateway URL and Discord session-start limit obtained through REST;
- a `ShardPlan` describing the shard IDs owned by this process;
- one fresh `GatewayTransportDriver` factory per connection attempt;
- a `GatewayCoordination` implementation for shard leases, session state, and
  IDENTIFY reservations;
- a bounded `GatewayDispatchRuntime` and event handler for each shard;
- token, intents, IDENTIFY properties, timeouts, clocks, sleep, and jitter.

Production composition uses `chronosGatewayClock`, `chronosGatewaySleep`,
`secureGatewayJitter`, and `chronosGatewayTransportFactory`. Tests can inject the
same contracts without opening a socket. The runner takes the initial URL as a
value and never hides a REST lookup inside connection startup.

`GatewayRuntime` supervises the runners produced for one shard plan. An
application that also uses `DiscordApp` should attach the runtime's start, wait,
and close operations before calling `app.run`, so HTTP, Gateway, and operator
resources have one shutdown owner.

## Connection sequence

One `GatewayShardRunner` performs this sequence:

1. Acquire the shard lease and fencing token.
2. Read saved session state under that token.
3. Start lease renewal and periodic session checkpoints.
4. For a fresh session, reserve a non-refundable IDENTIFY permit.
5. Connect the canonical Gateway URL.
6. Require HELLO within the configured timeout.
7. Schedule the first heartbeat with interval jitter.
8. RESUME a valid saved session, or send IDENTIFY with the reserved permit.
9. Run one receive/decode loop beside the heartbeat task.
10. Reconnect, re-identify, or stop according to close code, opcode, lease state,
   and transport outcome.

The runner is one-shot. A second or concurrent `run` is a lifecycle error. Close
is idempotent and joins the in-progress shutdown, including connection tasks,
lease renewal, dispatch workers, native compression state, transport I/O, and
lease release.

## URL and compression

`buildGatewayUrl` preserves the host and path returned by Discord, replaces
conflicting query values, and adds Gateway version 10 with JSON encoding. RESUME
uses `resume_gateway_url` with the same query contract.

`gatewayCompressionNone` accepts complete UTF-8 JSON text messages.
`gatewayCompressionZlibStream` uses one inflate context for the connection. The
decoder buffers binary data until Discord's sync-flush marker, then continues
inflating with the same sliding-window history. It bounds compressed input and
inflated output independently and rejects malformed UTF-8 or JSON without
including the payload in the error.

The current decoder does not implement `zstd-stream`. Choose an advertised mode
the runtime supports.

## Heartbeat and session state

The first heartbeat delay is `heartbeat_interval * jitter`. Later heartbeats use
the full interval. A server OP 1 request sends an immediate heartbeat without
moving the periodic schedule.

If any periodic or server-requested heartbeat is still unacknowledged by the
next heartbeat attempt, the runner aborts and attempts RESUME. The reader never
waits on an application event handler, so a slow handler cannot prevent heartbeat
ACK, RECONNECT, INVALID_SESSION, or close processing.

READY replaces the session ID and resume URL. A dispatch sequence becomes the
resume cursor only after the event has entered the bounded dispatch runtime.
Periodic fenced checkpoints let a replacement owner continue from the last
stored cursor. A stale owner cannot read or write the new owner's session.

## Identify coordination

`GatewayCoordination` returns relative wait durations. The runner does not
compare its wall clock with a backend timestamp.

A granted `ShardLease` has an opaque fencing token. Renew, release, session
read, and session write require that exact token. Losing renewal is terminal for
the runner and aborts the active connection.

The lease TTL is a relative duration observed on the runner's monotonic clock.
The runner records a conservative local expiry and renews no later than halfway
through the remaining window, even when the configured renewal cadence is
longer. It checks that local ownership immediately before connect, handshake,
and dispatch admission. A process that stalls past the TTL cannot resume work as
the old owner.

Session reads and renewal calls are bounded by the local lease expiry. Session
checkpoints use the earlier of a checkpoint budget and that expiry. A timeout or
ambiguous checkpoint fails closed because a late write under the same fencing
token could otherwise replace a newer cursor. IDENTIFY reservation, connect,
HELLO, and handshake sends race the same abort signal, so lease loss interrupts
pre-session work. Shutdown also bounds lease release; backend TTL expiry remains
the final recovery mechanism if release cannot complete.

`reserveIdentify` applies Discord's total session-start budget and
`max_concurrency` buckets. A granted permit is not refunded after a connection
or send failure because Discord may already have observed the attempt.

`LocalGatewayCoordination` provides deterministic single-process behavior and
tests the full contract. It is not suitable for coordinating separate hosts.
Redis, etcd, SQL, or another production backend must implement atomic lease and
fencing operations using backend time.

## Dispatch policy

Choose one explicit policy:

- `orderedPolicy` sends every event through one FIFO lane;
- `partitionedPolicy` runs several lanes while keeping one guild's events in the
  same lane;
- `concurrentPolicy` distributes events round-robin and does not promise ordering
  across lanes.

Each lane has a fixed queue capacity. `submit` never waits. On overload, the
runner leaves the event's sequence unobserved, aborts the connection, and resumes
from the previous admitted sequence.

Guild lifecycle events use their `id` as the partition key. Other guild-scoped
events use `guild_id`. This keeps `GUILD_CREATE`, member, channel, thread,
presence, and message mutations for one guild ordered under the partitioned
policy.

Handler failures do not stop a lane. `DispatchErrorContext` reports the event
name, shard, sequence, partition, lane, and exception type without the exception
message or payload.

## Multi-shard supervision

`GatewayRuntime` builds runners in ascending shard order and closes them in
reverse order. With the default restart policy, the first terminal shard failure
closes every other runner and raises `GatewayRuntimeError` with a stable,
redacted reason.

`GatewayRestartPolicy.maxRestarts` is a finite per-shard budget. A replacement
runner must be a new owner with its own dispatch runtime and transport factory.
There is no infinite background restart loop.

## Application lifecycle integration

`attachGatewayRuntime`, in the composition module `cordnim/app/gateway_runtime`,
binds an owned `GatewayRuntime` to a `DiscordApp` as one runtime component. The
application starts it in attachment order and closes it in reverse beside an
HTTP interaction runtime, if any, from a single `run`. The low-level Gateway
modules never import the application layer; this module is the only bridge.

```nim
import cordnim/app
import cordnim/app/gateway_runtime
import cordnim/gateway/runtime

let application = newDiscordApp(
  services, initAppConfig(ingressGateway), commands)

let runtime = newGatewayRuntime(plan, runnerFactory)
attachGatewayRuntime(application, runtime)

await application.run()   # start, join the fleet, then close as one owner
```

The adapter wraps the runtime's synchronous one-shot `start`, its `join` wait,
and its idempotent `close`, and spawns nothing of its own. The runtime keeps
sole ownership of its supervisor task. It rejects a nil app or runtime, a
webhook-only application whose configuration needs no Gateway connection, and
attachment after the app has left the ready state.

## Selective entity cache

`newEntityCache` takes a `CachePolicies` value that chooses an independent policy
for guilds, channels and threads, members, presences, and messages. A disabled
store retains nothing. Deletes cascade from the owning-guild scope recorded with
each child snapshot rather than from any reverse index, so a guild delete removes
enabled children even when the channel store is disabled or has evicted the
parent.

The cache consumes:

- guild create, update, unavailable, delete, and availability recovery;
- channel and thread create, update, delete, and thread-list synchronization;
- member add, update, remove, and member chunks;
- presence updates;
- message create, update, delete, and bulk delete.

An available `GUILD_CREATE` is authoritative for its channel and active-thread
lists. Member and presence arrays remain partial and do not purge omitted
entries. `THREAD_LIST_SYNC` reconciles the named parent channels, or the whole
guild when `channel_ids` is absent.

Each supported event's object shape, required identifiers, and relevant nested
arrays are validated before any mutation. A present-but-invalid optional field is
malformed rather than treated as absent. Partial updates merge known and unknown
fields into the stored semantic JSON. Lookups parse a fresh node, so the caller
does not receive a mutable cache alias.

`cachingHandler` applies cache state before it invokes the raw event handler. A
cache error reaches a redacted observer but does not suppress raw event delivery.

## Shutdown and observability

Shutdown must begin at the highest owner. Close the multi-shard runtime before a
coordination client or shared HTTP/WebSocket resource it uses. Do not abandon a
runner's `run` future.

Safe operational fields include shard ID, close code, lifecycle phase, event
name, sequence, queue depth, restart count, and coordination error kind. Do not
log bot tokens, session payloads, raw events, backend exception messages, or
rendered callback URLs.

Discord's [Gateway documentation](https://docs.discord.com/developers/events/gateway)
and [Gateway Events reference](https://docs.discord.com/developers/events/gateway-events)
define the current opcodes, events, intents, sharding, and session-start rules.
