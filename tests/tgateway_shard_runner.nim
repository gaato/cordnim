## Deterministic injected-driver tests for the Gateway shard runner.
##
## Time is virtual (a hand-advanced clock plus a sleeper that completes only when
## the clock passes a wait's deadline), and the transport is a scripted driver
## whose inbox delivers server frames and whose outbox captures sent frames. No
## sockets and no wall-clock time are involved, so every lifecycle path is driven
## exactly.

import std/[json, options, strutils]

import chronos

import cordnim/core/secrets
import cordnim/gateway/[
  close_policy, compression, coordination, dispatch, dispatch_runtime, identify,
  payloads, session, shard_runner, supervisor, transport, url]

# --------------------------------------------------------------------------- #
# Virtual timeline: a clock plus a sleeper wired to it.
# --------------------------------------------------------------------------- #

type Timeline = ref object
  nowMs: int64
  waiters: seq[tuple[due: int64, fut: GatewaySleepFuture]]

proc advance(tl: Timeline; deltaMs: int64) =
  ## Advances virtual time and completes every sleeper whose deadline passed.
  tl.nowMs += deltaMs
  var remaining: seq[tuple[due: int64, fut: GatewaySleepFuture]]
  for waiter in tl.waiters:
    if waiter.fut.finished:
      continue
    if waiter.due <= tl.nowMs:
      waiter.fut.complete()
    else:
      remaining.add waiter
  tl.waiters = remaining

proc pendingSleeps(tl: Timeline): int =
  for waiter in tl.waiters:
    if not waiter.fut.finished:
      inc result

proc makeClock(tl: Timeline): GatewayClock =
  result = proc(): int64 {.gcsafe, raises: [].} = tl.nowMs

proc makeSleeper(tl: Timeline): GatewaySleeper =
  result = proc(ms: int64): GatewaySleepFuture {.gcsafe, raises: [].} =
    let fut = GatewaySleepFuture.init("test.sleep")
    if ms <= 0:
      fut.complete()
    else:
      tl.waiters.add (tl.nowMs + ms, fut)
    fut

# `jitter(span) == span` delays the first heartbeat by a full interval, so no
# heartbeat fires until a test advances the clock.
proc fullSpanJitter(): GatewayJitter =
  result = proc(span: int64): int64 {.gcsafe, raises: [].} = span

proc halfSpanJitter(): GatewayJitter =
  result = proc(span: int64): int64 {.gcsafe, raises: [].} = span div 2

# --------------------------------------------------------------------------- #
# Scripted transport driver.
# --------------------------------------------------------------------------- #

type ScriptedDriver = ref object
  inbox: AsyncQueue[GatewayTransportEvent]
  outbox: AsyncQueue[string]
  connectUrls: seq[string]
  closeCount: int
  abortCount: int
  receiveActive: bool
  pendingConnect: bool ## When set, connectProc never completes on its own.

proc newScriptedDriver(): ScriptedDriver =
  ScriptedDriver(
    inbox: newAsyncQueue[GatewayTransportEvent](),
    outbox: newAsyncQueue[string]())

proc push(d: ScriptedDriver; event: GatewayTransportEvent) =
  try: d.inbox.putNoWait(event)
  except AsyncQueueFullError: doAssert false

proc nextSent(d: ScriptedDriver): string =
  waitFor d.outbox.get()

proc asFactory(d: ScriptedDriver): GatewayTransportFactory =
  result = proc(): GatewayTransportDriver {.gcsafe, raises: [].} =
    let onConnect = proc(url: string): GatewayDriverVoidFuture {.
        gcsafe, raises: [].} =
      d.connectUrls.add url
      result = GatewayDriverVoidFuture.init("t.connect")
      if not d.pendingConnect:
        result.complete()
    let onSend = proc(msg: GatewayMessage): GatewayDriverVoidFuture {.
        gcsafe, raises: [].} =
      if msg.kind == gatewayTextMessage:
        try: d.outbox.putNoWait(msg.text())
        except CatchableError: discard
      result = GatewayDriverVoidFuture.init("t.send")
      result.complete()
    let onReceive = proc(): Future[GatewayTransportEvent] {.gcsafe,
        async: (raises: [CancelledError, GatewayTransportError]).} =
      d.receiveActive = true
      try:
        return await d.inbox.get()
      finally:
        d.receiveActive = false
    let onClose = proc(code: GatewayCloseCode; reason: string):
        GatewayDriverVoidFuture {.gcsafe, raises: [].} =
      inc d.closeCount
      result = GatewayDriverVoidFuture.init("t.close")
      result.complete()
    let onAbort = proc() {.gcsafe, raises: [].} =
      inc d.abortCount
    try:
      result = newGatewayTransportDriver(
        onConnect, onSend, onReceive, onClose, onAbort)
    except ValueError:
      raiseAssert "test driver closures are non-nil"

# --------------------------------------------------------------------------- #
# Server frame builders (uncompressed JSON text).
# --------------------------------------------------------------------------- #

proc textEvent(payload: string): GatewayTransportEvent =
  messageEvent(textGatewayMessage(payload))

proc helloEvent(intervalMs: int): GatewayTransportEvent =
  textEvent("""{"op":10,"d":{"heartbeat_interval":""" & $intervalMs & "}}")

proc readyEvent(seqNo: int; sessionId, resumeUrl: string): GatewayTransportEvent =
  textEvent("""{"op":0,"s":""" & $seqNo & ""","t":"READY","d":{"session_id":"""" &
    sessionId & """","resume_gateway_url":"""" & resumeUrl & """"}}""")

proc dispatchEvent(seqNo: int; name: string): GatewayTransportEvent =
  textEvent("""{"op":0,"s":""" & $seqNo & ""","t":"""" & name & """","d":{}}""")

proc interactionEvent(seqNo: int; token: string): GatewayTransportEvent =
  textEvent($(%*{
    "op": 0,
    "s": seqNo,
    "t": "INTERACTION_CREATE",
    "d": {
      "id": "100",
      "application_id": "200",
      "token": token,
      "type": 1
    }
  }))

proc serverHeartbeatEvent(): GatewayTransportEvent =
  textEvent("""{"op":1,"d":null}""")
proc reconnectEvent(): GatewayTransportEvent = textEvent("""{"op":7,"d":null}""")
proc invalidSessionEvent(resumable: bool): GatewayTransportEvent =
  textEvent("""{"op":9,"d":""" & $resumable & "}")
proc closeFrame(code: uint16): GatewayTransportEvent =
  closeEvent(GatewayCloseInfo(code: GatewayCloseCode(code), reason: "", clean: true))

# --------------------------------------------------------------------------- #
# Dispatch probe.
# --------------------------------------------------------------------------- #

type Probe = ref object
  processed: seq[string]
  receivedAtMs: seq[int64]
  reached: AsyncEvent
  target: int
  gate: AsyncEvent
  gated: bool

proc newProbe(): Probe = Probe(reached: newAsyncEvent(), gate: newAsyncEvent())

proc handler(probe: Probe): GatewayDispatchHandler =
  result = proc(event: DispatchEvent): Future[void] {.async.} =
    if probe.gated:
      await probe.gate.wait()
    probe.processed.add event.name
    probe.receivedAtMs.add event.receivedAtMs
    if probe.target > 0 and probe.processed.len >= probe.target:
      probe.reached.fire()

type InteractionProbe = ref object
  calls: int
  payload: JsonNode
  receivedAtMs: int64
  reached: AsyncEvent
  completed: AsyncEvent
  completedCalls: int
  gate: AsyncEvent
  gated: bool

proc newInteractionProbe(): InteractionProbe =
  InteractionProbe(
    reached: newAsyncEvent(), completed: newAsyncEvent(), gate: newAsyncEvent())

proc sink(probe: InteractionProbe): GatewayInteractionSink =
  result = proc(interaction: JsonNode; receivedAtMs: int64): Future[void] {.
      gcsafe, raises: [].} =
    proc run(): Future[void] {.async.} =
      inc probe.calls
      probe.payload = interaction.copy()
      probe.receivedAtMs = receivedAtMs
      probe.reached.fire()
      if probe.gated:
        await probe.gate.wait()
      inc probe.completedCalls
      probe.completed.fire()
    {.cast(gcsafe).}:
      return run()

# --------------------------------------------------------------------------- #
# Harness.
# --------------------------------------------------------------------------- #

type Harness = ref object
  tl: Timeline
  driver: ScriptedDriver
  probe: Probe
  local: LocalGatewayCoordination
  coordination: GatewayCoordination
  dispatch: GatewayDispatchRuntime
  runner: GatewayShardRunner

proc defaultLimit(): SessionStartLimit =
  SessionStartLimit(total: 100, remaining: 100, resetAfterMs: 60_000, maxConcurrency: 1)

proc baseConfig(): GatewayShardRunnerConfig =
  GatewayShardRunnerConfig(
    shardId: ShardId(0),
    totalShards: 1,
    token: initSecret[BotToken]("test-token"),
    identifyProperties: initGatewayIdentifyProperties("linux", "cordnim", "cordnim"),
    intents: 0'u64,
    initialUrl: "wss://gateway.discord.gg/",
    compression: gatewayCompressionNone,
    helloTimeoutMs: 20_000,
    leaseRenewIntervalMs: 30_000,
    reconnectBackoffMs: 0,
  )

proc newHarness(
    coordination: GatewayCoordination = nil;
    jitter: GatewayJitter = nil;
    policy = orderedPolicy(16);
    interactionSink: GatewayInteractionSink = nil,
    interactionMaxConcurrent = 4,
): Harness =
  let tl = Timeline()
  let probe = newProbe()
  let driver = newScriptedDriver()
  var local: LocalGatewayCoordination
  var coord = coordination
  if coord.isNil:
    local = newLocalGatewayCoordination(makeClock(tl), 60_000, defaultLimit())
    coord = local.asCoordination()
  let dispatch = newGatewayDispatchRuntime(policy, handler(probe))
  let runner = newGatewayShardRunner(
    baseConfig(), coord, dispatch, driver.asFactory(),
    makeClock(tl), makeSleeper(tl),
    if jitter.isNil: fullSpanJitter() else: jitter,
    interactionSink = interactionSink,
    interactionMaxConcurrent = interactionMaxConcurrent)
  Harness(
    tl: tl, driver: driver, probe: probe, local: local,
    coordination: coord, dispatch: dispatch, runner: runner)

# Drive to the point where the runner has sent its handshake frame (IDENTIFY or
# RESUME) after a HELLO with the given interval.
proc handshakeAfterHello(h: Harness; intervalMs: int): JsonNode =
  h.driver.push(helloEvent(intervalMs))
  parseJson(h.driver.nextSent())

# Advance virtual time in steps, pumping the loop, until a predicate holds or a
# frame is sent. `sleepAsync(0)` (a real zero timer) drains ready callbacks so the
# loop never blocks on the OS selector with only virtual sleeps pending.
proc pumpUntil(h: Harness; cond: proc(): bool {.raises: [].}): bool =
  for _ in 0 ..< 4000:
    if cond(): return true
    h.tl.advance(50)
    waitFor sleepAsync(0.milliseconds)
  cond()

proc pumpUntilSent(h: Harness): string =
  for _ in 0 ..< 4000:
    if h.driver.outbox.len > 0: return waitFor h.driver.outbox.get()
    h.tl.advance(50)
    waitFor sleepAsync(0.milliseconds)
  doAssert false, "expected a sent frame"
  ""

# =========================================================================== #
# Tests
# =========================================================================== #

block config_validation_is_enforced:
  let tl = Timeline()
  let driver = newScriptedDriver()
  let dispatch = newGatewayDispatchRuntime(orderedPolicy(4), handler(newProbe()))
  let local = newLocalGatewayCoordination(makeClock(tl), 60_000, defaultLimit())
  proc build(mutate: proc(c: var GatewayShardRunnerConfig)): GatewayShardRunner =
    var cfg = baseConfig()
    mutate(cfg)
    newGatewayShardRunner(
      cfg, local.asCoordination(), dispatch, driver.asFactory(),
      makeClock(tl), makeSleeper(tl), fullSpanJitter())
  doAssertRaises ValueError: # shard id must be < total
    discard build(proc(c: var GatewayShardRunnerConfig) = (c.shardId = ShardId(3); c.totalShards = 2))
  doAssertRaises ValueError: # total shards zero
    discard build(proc(c: var GatewayShardRunnerConfig) = c.totalShards = 0)
  doAssertRaises ValueError: # negative backoff
    discard build(proc(c: var GatewayShardRunnerConfig) = c.reconnectBackoffMs = -1)
  doAssertRaises ValueError: # non-positive timeout
    discard build(proc(c: var GatewayShardRunnerConfig) = c.helloTimeoutMs = 0)
  doAssertRaises GatewayUrlError: # bad initial URL
    discard build(proc(c: var GatewayShardRunnerConfig) = c.initialUrl = "http://x/")
  doAssertRaises ValueError: # non-positive interaction concurrency
    discard newGatewayShardRunner(
      baseConfig(), local.asCoordination(), dispatch, driver.asFactory(),
      makeClock(tl), makeSleeper(tl), fullSpanJitter(),
      interactionMaxConcurrent = 0)

block identify_ready_checkpoint_and_autostart:
  let h = newHarness()
  h.probe.target = 1
  let runFut = h.runner.run()
  let identify = h.handshakeAfterHello(45_000)
  doAssert identify["op"].getInt == 2 # IDENTIFY
  doAssert identify["d"]["shard"] == %*[0, 1]
  doAssert h.runner.lifecycle == shardIdentifying
  # READY must be dispatch-admitted (proving the dispatch runtime auto-started),
  # then its session/sequence adopted and checkpointed.
  h.tl.advance(123)
  h.driver.push(readyEvent(10, "sess-a", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  doAssert h.probe.processed == @["READY"]
  doAssert h.probe.receivedAtMs == @[123'i64]
  doAssert h.runner.lifecycle == shardReady
  let snap = h.runner.sessionSnapshot
  doAssert snap.canResume
  doAssert snap.resumeCursor.sessionId == "sess-a"
  doAssert snap.resumeCursor.sequence.toInt64 == 10
  waitFor h.runner.close()
  waitFor runFut
  # The checkpoint persisted: a fresh lease reads back the adopted session.
  let lease = waitFor h.local.acquireShard(ShardId(0))
  let stored = waitFor h.local.readSession(lease.lease)
  doAssert stored.status == sessionRead
  doAssert stored.state.get.sessionId == "sess-a"
  # No sleeper or receive is left pending after teardown.
  doAssert h.tl.pendingSleeps == 0
  doAssert not h.driver.receiveActive

block interactions_bypass_the_generic_feed_with_and_without_a_sink:
  const sentinel = "RUNNER_INTERACTION_SECRET"

  block with_sink:
    let interactionProbe = newInteractionProbe()
    let h = newHarness(interactionSink = interactionProbe.sink())
    h.probe.target = 1
    let runFut = h.runner.run()
    discard h.handshakeAfterHello(45_000)
    h.driver.push(readyEvent(1, "sess-i", "wss://resume.example/"))
    waitFor h.probe.reached.wait()
    h.tl.advance(25)
    h.driver.push(interactionEvent(2, sentinel))
    waitFor interactionProbe.reached.wait()
    doAssert interactionProbe.calls == 1
    doAssert interactionProbe.payload["token"].getStr() == sentinel
    doAssert interactionProbe.receivedAtMs == 25
    doAssert h.probe.processed == @["READY"]
    doAssert h.runner.sessionSnapshot.sequence.get().toInt64() == 2
    waitFor h.runner.close()
    waitFor runFut

  block without_sink:
    let h = newHarness()
    h.probe.target = 1
    let runFut = h.runner.run()
    discard h.handshakeAfterHello(45_000)
    h.driver.push(readyEvent(1, "sess-j", "wss://resume.example/"))
    waitFor h.probe.reached.wait()
    h.driver.push(interactionEvent(2, sentinel))
    doAssert h.pumpUntil(proc(): bool {.raises: [].} =
      h.runner.sessionSnapshot.sequence.isSome and
        h.runner.sessionSnapshot.sequence.get().toInt64() == 2)
    doAssert h.probe.processed == @["READY"]
    waitFor h.runner.close()
    waitFor runFut

block admitted_interaction_survives_connection_replacement:
  let interactionProbe = newInteractionProbe()
  interactionProbe.gated = true
  let h = newHarness(interactionSink = interactionProbe.sink())
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(readyEvent(1, "sess-k", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  h.driver.push(interactionEvent(2, "PERSISTENT_INTERACTION_SECRET"))
  waitFor interactionProbe.reached.wait()
  h.driver.push(reconnectEvent())
  h.driver.push(helloEvent(45_000))
  let resume = parseJson(h.pumpUntilSent())
  doAssert resume["op"].getInt() == 6
  interactionProbe.gate.fire()
  waitFor interactionProbe.completed.wait()
  doAssert interactionProbe.calls == 1
  waitFor h.runner.close()
  waitFor runFut

block slow_interaction_does_not_age_the_next_ack_in_the_queue:
  let interactionProbe = newInteractionProbe()
  interactionProbe.gated = true
  let h = newHarness(interactionSink = interactionProbe.sink())
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(readyEvent(1, "sess-concurrent", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  h.driver.push(interactionEvent(2, "SLOW_A"))
  h.driver.push(interactionEvent(3, "PROMPT_B"))
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = interactionProbe.calls == 2)
  doAssert h.runner.sessionSnapshot.sequence.get().toInt64() == 3
  interactionProbe.gate.fire()
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = interactionProbe.completedCalls == 2)
  waitFor h.runner.close()
  waitFor runFut

block interaction_queue_overload_preserves_the_last_admitted_cursor:
  let interactionProbe = newInteractionProbe()
  interactionProbe.gated = true
  let h = newHarness(
    policy = orderedPolicy(1), interactionSink = interactionProbe.sink(),
    interactionMaxConcurrent = 1)
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(readyEvent(1, "sess-l", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  let abortsBefore = h.driver.abortCount
  h.driver.push(interactionEvent(2, "A"))
  waitFor interactionProbe.reached.wait()
  h.driver.push(interactionEvent(3, "B"))
  h.driver.push(interactionEvent(4, "C"))
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = h.driver.abortCount > abortsBefore)
  doAssert h.runner.sessionSnapshot.sequence.get().toInt64() <= 3
  interactionProbe.gate.fire()
  waitFor h.runner.close()
  waitFor runFut

block resume_uses_stored_session_and_resume_url:
  # Seed a resumable session under a lease, release it, then a fresh runner must
  # RESUME rather than IDENTIFY.
  let tl = Timeline()
  let local = newLocalGatewayCoordination(makeClock(tl), 60_000, defaultLimit())
  block:
    let lease = waitFor local.acquireShard(ShardId(0))
    var state = initGatewaySession(ShardId(0))
    state.recordReady("prior-session", "wss://resume.example/")
    discard state.observeSequence(GatewaySequence(77))
    doAssert (waitFor local.writeSession(lease.lease, state)) == sessionWritten
    doAssert (waitFor local.releaseShard(lease.lease)) == leaseReleased
  let driver = newScriptedDriver()
  let dispatch = newGatewayDispatchRuntime(orderedPolicy(8), handler(newProbe()))
  let runner = newGatewayShardRunner(
    baseConfig(), local.asCoordination(), dispatch, driver.asFactory(),
    makeClock(tl), makeSleeper(tl), fullSpanJitter())
  let runFut = runner.run()
  driver.push(helloEvent(45_000))
  let resume = parseJson(driver.nextSent())
  doAssert resume["op"].getInt == 6 # RESUME
  doAssert resume["d"]["session_id"].getStr == "prior-session"
  doAssert resume["d"]["seq"].getInt == 77
  doAssert runner.lifecycle == shardResuming
  # The resume connection targets the canonical resume URL, not the initial one.
  doAssert driver.connectUrls[^1] == buildGatewayUrl("wss://resume.example/")
  waitFor runner.close()
  waitFor runFut

block server_heartbeat_is_answered_immediately:
  let h = newHarness()
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000) # IDENTIFY
  # An OP1 request is answered with an OP1 heartbeat without advancing the clock.
  h.driver.push(serverHeartbeatEvent())
  let hb = parseJson(h.driver.nextSent())
  doAssert hb["op"].getInt == 1
  waitFor h.runner.close()
  waitFor runFut

block missed_ack_aborts_before_next_periodic_send:
  let h = newHarness(jitter = halfSpanJitter())
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(10_000) # IDENTIFY
  # First heartbeat fires at interval/2 (5s) per the jitter.
  h.tl.advance(5_000)
  let hb1 = parseJson(h.driver.nextSent())
  doAssert hb1["op"].getInt == 1
  # No ACK arrives; advancing to the next periodic deadline must abort the
  # connection and release the transport.
  let abortsBefore = h.driver.abortCount
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = h.driver.abortCount > abortsBefore)
  waitFor h.runner.close()
  waitFor runFut

block server_reconnect_triggers_resume:
  let h = newHarness()
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000) # IDENTIFY
  h.driver.push(readyEvent(5, "sess-x", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  # OP7 ends the connection; with a resumable session the runner reconnects and
  # RESUMEs (backoff is zero), producing a second handshake frame.
  h.driver.push(reconnectEvent())
  h.driver.push(helloEvent(45_000))
  let second = parseJson(h.pumpUntilSent())
  doAssert second["op"].getInt == 6 # RESUME after reconnect
  doAssert second["d"]["session_id"].getStr == "sess-x"
  waitFor h.runner.close()
  waitFor runFut

block invalid_session_false_forces_identify:
  let h = newHarness()
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(readyEvent(5, "sess-y", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  # OP9 false invalidates the session; the reconnect must IDENTIFY afresh.
  h.driver.push(invalidSessionEvent(false))
  h.driver.push(helloEvent(45_000))
  let second = parseJson(h.pumpUntilSent())
  doAssert second["op"].getInt == 2 # IDENTIFY, not RESUME
  waitFor h.runner.close()
  waitFor runFut

block invalid_session_true_allows_resume:
  let h = newHarness()
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(readyEvent(5, "sess-z", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  h.driver.push(invalidSessionEvent(true))
  h.driver.push(helloEvent(45_000))
  let second = parseJson(h.pumpUntilSent())
  doAssert second["op"].getInt == 6 # RESUME
  waitFor h.runner.close()
  waitFor runFut

block hello_timeout_aborts_and_reconnects:
  let h = newHarness()
  let runFut = h.runner.run()
  # Advance past the HELLO timeout with no HELLO delivered; the runner must abort.
  let abortsBefore = h.driver.abortCount
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = h.driver.abortCount > abortsBefore)
  doAssert h.driver.connectUrls.len >= 1 # it did connect first
  waitFor h.runner.close()
  waitFor runFut

block dispatch_overload_aborts_and_preserves_cursor:
  # One-slot lane with a blocked handler: the third event overflows and the
  # runner aborts, having advanced the cursor only for admitted events.
  let h = newHarness(policy = orderedPolicy(1))
  h.probe.gated = true
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  let abortsBefore = h.driver.abortCount
  h.driver.push(dispatchEvent(1, "A")) # admitted, handler blocks
  h.driver.push(dispatchEvent(2, "B")) # admitted, queued
  h.driver.push(dispatchEvent(3, "C")) # overflow -> abort + resume
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = h.driver.abortCount > abortsBefore)
  # The cursor never advanced past the last admitted sequence (2).
  doAssert h.runner.sessionSnapshot.sequence.get.toInt64 <= 2
  h.probe.gate.fire()
  waitFor h.runner.close()
  waitFor runFut

block close_is_idempotent_and_double_run_is_rejected:
  let h = newHarness()
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  # A second run while running is rejected.
  doAssertRaises GatewayShardRunnerError:
    waitFor h.runner.run()
  waitFor h.runner.close()
  waitFor h.runner.close() # idempotent
  waitFor runFut
  doAssert h.tl.pendingSleeps == 0
  doAssert not h.driver.receiveActive

block close_before_run_never_acquires:
  let h = newHarness()
  waitFor h.runner.close()
  waitFor h.runner.run() # returns immediately; acquires nothing
  # The shard was never connected.
  doAssert h.driver.connectUrls.len == 0

block cancelling_run_tears_down_cleanly:
  let h = newHarness()
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  runFut.cancelSoon()
  try: waitFor runFut
  except CancelledError: discard
  except CatchableError: discard
  # Teardown left nothing pending.
  waitFor h.runner.close()
  doAssert h.tl.pendingSleeps == 0
  doAssert not h.driver.receiveActive

# --------------------------------------------------------------------------- #
# Fail-closed coordination stubs.
# --------------------------------------------------------------------------- #

proc okAcquire(shardId: ShardId): ShardAcquireFuture {.gcsafe, raises: [].} =
  result = ShardAcquireFuture.init("s.acq")
  result.complete(ShardAcquireResult(
    status: shardAcquired,
    lease: ShardLease(shardId: shardId, token: FencingToken(1), ttlMs: 60_000)))

proc okRead(lease: ShardLease): SessionReadFuture {.gcsafe, raises: [].} =
  result = SessionReadFuture.init("s.read")
  result.complete(SessionReadResult(
    status: sessionRead, state: none(GatewaySessionState)))

proc okReserve(shardId: ShardId): IdentifyReservationFuture {.gcsafe, raises: [].} =
  result = IdentifyReservationFuture.init("s.res")
  result.complete(IdentifyReservation(
    maxConcurrency: 1, remaining: 1, resetAfterMs: 1000, status: identifyReserved,
    lease: IdentifyLease(shardId: shardId, bucket: 0)))

proc okWrite(lease: ShardLease; state: GatewaySessionState): SessionWriteFuture {.
    gcsafe, raises: [].} =
  result = SessionWriteFuture.init("s.write")
  result.complete(sessionWritten)

proc okRelease(lease: ShardLease): LeaseReleaseFuture {.gcsafe, raises: [].} =
  result = LeaseReleaseFuture.init("s.rel")
  result.complete(leaseReleased)

proc lostRenew(lease: ShardLease): LeaseRenewFuture {.gcsafe, raises: [].} =
  result = LeaseRenewFuture.init("s.renew")
  result.complete(LeaseRenewResult(status: leaseLost))

proc leaseLossCoordination(): GatewayCoordination =
  newGatewayCoordination(
    okAcquire, lostRenew, okRelease, okReserve, okWrite, okRead)

proc erroringAcquire(shardId: ShardId): ShardAcquireFuture {.gcsafe, raises: [].} =
  result = ShardAcquireFuture.init("s.acq.err")
  result.fail(newGatewayCoordinationError(ceUnavailable, "backend-secret-detail"))

proc okRenew(lease: ShardLease): LeaseRenewFuture {.gcsafe, raises: [].} =
  result = LeaseRenewFuture.init("s.renew.ok")
  result.complete(LeaseRenewResult(status: leaseRenewed, lease: lease))

proc backendErrorCoordination(): GatewayCoordination =
  newGatewayCoordination(
    erroringAcquire, okRenew, okRelease, okReserve, okWrite, okRead)

proc pendingAcquire(shardId: ShardId): ShardAcquireFuture {.gcsafe, raises: [].} =
  ShardAcquireFuture.init("s.acq.pending") # never completes on its own

proc pendingAcquireCoordination(): GatewayCoordination =
  newGatewayCoordination(
    pendingAcquire, okRenew, okRelease, okReserve, okWrite, okRead)

proc settle(times = 8) =
  for _ in 0 ..< times:
    waitFor sleepAsync(0.milliseconds)

proc shortTtlAcquire(shardId: ShardId): ShardAcquireFuture {.gcsafe, raises: [].} =
  result = ShardAcquireFuture.init("s.acq.short")
  result.complete(ShardAcquireResult(status: shardAcquired,
    lease: ShardLease(shardId: shardId, token: FencingToken(1), ttlMs: 2_000)))

var renewCount {.threadvar.}: int
proc countingShortRenew(lease: ShardLease): LeaseRenewFuture {.gcsafe, raises: [].} =
  inc renewCount
  result = LeaseRenewFuture.init("s.renew.count")
  result.complete(LeaseRenewResult(status: leaseRenewed,
    lease: ShardLease(shardId: lease.shardId, token: lease.token, ttlMs: 2_000)))

proc pendingRenew(lease: ShardLease): LeaseRenewFuture {.gcsafe, raises: [].} =
  LeaseRenewFuture.init("s.renew.pending") # never completes
proc pendingReserve(shardId: ShardId): IdentifyReservationFuture {.gcsafe, raises: [].} =
  IdentifyReservationFuture.init("s.res.pending")
proc pendingRead(lease: ShardLease): SessionReadFuture {.gcsafe, raises: [].} =
  SessionReadFuture.init("s.read.pending")

proc pendingReserveCoordination(): GatewayCoordination =
  newGatewayCoordination(okAcquire, okRenew, okRelease, pendingReserve, okWrite, okRead)
proc pendingReadCoordination(): GatewayCoordination =
  newGatewayCoordination(okAcquire, okRenew, okRelease, okReserve, okWrite, pendingRead)
proc shortTtlPendingReadCoordination(): GatewayCoordination =
  newGatewayCoordination(shortTtlAcquire, okRenew, okRelease, okReserve, okWrite, pendingRead)
proc pendingRenewCoordination(): GatewayCoordination =
  newGatewayCoordination(shortTtlAcquire, pendingRenew, okRelease, okReserve, okWrite, okRead)
proc shortTtlLostCoordination(): GatewayCoordination =
  newGatewayCoordination(shortTtlAcquire, lostRenew, okRelease, okReserve, okWrite, okRead)
proc shortTtlLongIntervalCoordination(): GatewayCoordination =
  newGatewayCoordination(shortTtlAcquire, countingShortRenew, okRelease, okReserve, okWrite, okRead)

proc pendingWrite(lease: ShardLease; state: GatewaySessionState): SessionWriteFuture {.
    gcsafe, raises: [].} =
  SessionWriteFuture.init("s.write.pending") # never completes
proc pendingRelease(lease: ShardLease): LeaseReleaseFuture {.gcsafe, raises: [].} =
  LeaseReleaseFuture.init("s.rel.pending") # never completes

proc pendingWriteCoordination(): GatewayCoordination =
  newGatewayCoordination(shortTtlAcquire, okRenew, okRelease, okReserve, pendingWrite, okRead)
proc pendingReleaseCoordination(): GatewayCoordination =
  newGatewayCoordination(okAcquire, okRenew, pendingRelease, okReserve, okWrite, okRead)

block close_joins_run_blocked_on_never_completing_acquire:
  # run() parks on a coordination future that never completes and is not raced
  # with abort; close must cancel and join it, returning only after run exits.
  let h = newHarness(coordination = pendingAcquireCoordination())
  let runFut = h.runner.run()
  settle() # let run reach the pending acquire
  doAssert not runFut.finished
  waitFor h.runner.close() # returns only after cancelling/joining the run
  waitFor runFut
  doAssert h.driver.connectUrls.len == 0 # never connected
  doAssert h.tl.pendingSleeps == 0

block close_joins_run_blocked_on_never_completing_connect:
  let h = newHarness()
  h.driver.pendingConnect = true
  let runFut = h.runner.run()
  settle() # let run reach the pending connect
  doAssert not runFut.finished
  doAssert h.driver.connectUrls.len == 1 # connect was attempted
  waitFor h.runner.close()
  waitFor runFut
  doAssert h.tl.pendingSleeps == 0

block lease_loss_interrupts_a_never_completing_connect:
  let h = newHarness(coordination = shortTtlLostCoordination())
  h.driver.pendingConnect = true
  let runFut = h.runner.run()
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = h.driver.connectUrls.len == 1)
  h.tl.advance(1_000) # renew at half the 2-second TTL, then observe leaseLost
  discard h.pumpUntil(proc(): bool {.raises: [].} = runFut.finished)
  var failed = false
  try:
    waitFor runFut
  except GatewayShardRunnerError as err:
    failed = true
    doAssert err.msg.find("lease lost") != -1
  doAssert failed
  doAssert h.driver.outbox.len == 0 # no IDENTIFY was sent after lease loss

block concurrent_close_calls_all_join:
  let h = newHarness()
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  # Two concurrent closes must both complete against one shared teardown.
  let a = h.runner.close()
  let b = h.runner.close()
  waitFor a
  waitFor b
  waitFor runFut
  doAssert h.tl.pendingSleeps == 0
  doAssert not h.driver.receiveActive

block lease_loss_fails_closed:
  let h = newHarness(coordination = leaseLossCoordination())
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(1_000) # IDENTIFY sent; renewer will lose the lease
  # Advance so the renewer wakes, renews, and observes the lost lease.
  h.tl.advance(30_000)
  var failed = false
  try:
    waitFor runFut
  except GatewayShardRunnerError as err:
    failed = true
    doAssert err.msg.find("lease lost") != -1
    doAssert err.msg.find("secret") == -1
  doAssert failed
  doAssert h.tl.pendingSleeps == 0

block coordination_backend_error_fails_closed:
  let h = newHarness(coordination = backendErrorCoordination())
  var failed = false
  try:
    waitFor h.runner.run()
  except GatewayShardRunnerError as err:
    failed = true
    # The runner surfaces a stable reason, never the backend's detail message.
    doAssert err.msg.find("backend-secret-detail") == -1
    doAssert err.msg.find("coordination backend error") != -1
  doAssert failed
  doAssert h.driver.connectUrls.len == 0 # never connected

block start_join_close_are_the_owner_shape:
  let h = newHarness()
  h.probe.target = 1
  h.runner.start() # explicit start (no join yet)
  discard h.handshakeAfterHello(45_000)
  h.driver.push(readyEvent(1, "sess-sj", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  doAssert h.runner.lifecycle == shardReady
  # A second start is rejected.
  doAssertRaises GatewayShardRunnerError:
    h.runner.start()
  # A detached joiner observes completion; close stops the shard and the joiner
  # then returns.
  let joiner = h.runner.join()
  doAssert not joiner.finished
  waitFor h.runner.close()
  waitFor joiner
  doAssert h.tl.pendingSleeps == 0

block join_surfaces_terminal_failure_after_start:
  # After an explicit start, join is the supported way to observe a terminal fail.
  let h = newHarness(coordination = backendErrorCoordination())
  h.runner.start()
  var failed = false
  try:
    waitFor h.runner.join()
  except GatewayShardRunnerError as err:
    failed = true
    doAssert err.msg.find("coordination backend error") != -1
  doAssert failed

block server_op1_outstanding_blocks_next_periodic_send:
  # Half-interval jitter puts the first periodic attempt (5s) before the OP1
  # heartbeat's periodic deadline (10s); with no ACK between attempts the run must
  # abort (attempt-to-attempt), sending no second heartbeat.
  let h = newHarness(jitter = halfSpanJitter())
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(10_000)
  h.driver.push(serverHeartbeatEvent())
  doAssert parseJson(h.driver.nextSent())["op"].getInt == 1 # OP1 outstanding
  let abortsBefore = h.driver.abortCount
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = h.driver.abortCount > abortsBefore)
  doAssert h.driver.outbox.len == 0 # no second heartbeat was ever sent
  waitFor h.runner.close()
  waitFor runFut

block close_joins_run_blocked_on_never_completing_reserve:
  let h = newHarness(coordination = pendingReserveCoordination())
  let runFut = h.runner.run()
  settle()
  doAssert not runFut.finished
  doAssert h.driver.connectUrls.len == 0 # reserve is before connect
  waitFor h.runner.close()
  waitFor runFut
  doAssert h.tl.pendingSleeps == 0

block close_joins_run_blocked_on_never_completing_read:
  let h = newHarness(coordination = pendingReadCoordination())
  let runFut = h.runner.run()
  settle()
  doAssert not runFut.finished
  waitFor h.runner.close()
  waitFor runFut
  doAssert h.tl.pendingSleeps == 0

block close_joins_run_blocked_awaiting_hello:
  let h = newHarness()
  let runFut = h.runner.run()
  doAssert h.pumpUntil(
    proc(): bool {.raises: [].} = h.driver.connectUrls.len > 0)
  doAssert not runFut.finished
  doAssert h.driver.receiveActive # parked in the pre-HELLO receive
  waitFor h.runner.close()
  waitFor runFut
  doAssert not h.driver.receiveActive

block peer_close_4000_resumes:
  let h = newHarness()
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(readyEvent(5, "sess-c", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  h.driver.push(closeFrame(4000))
  h.driver.push(helloEvent(45_000))
  doAssert parseJson(h.pumpUntilSent())["op"].getInt == 6 # RESUME
  waitFor h.runner.close()
  waitFor runFut

block peer_close_4007_invalidates_then_identifies:
  let h = newHarness()
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(readyEvent(5, "sess-d", "wss://resume.example/"))
  waitFor h.probe.reached.wait()
  h.driver.push(closeFrame(4007))
  h.driver.push(helloEvent(45_000))
  doAssert parseJson(h.pumpUntilSent())["op"].getInt == 2 # IDENTIFY, new session
  waitFor h.runner.close()
  waitFor runFut

block peer_close_4014_is_terminal:
  let h = newHarness()
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(closeFrame(4014))
  var failed = false
  try:
    waitFor runFut
  except GatewayShardRunnerError as err:
    failed = true
    doAssert err.msg.find("4014") != -1 # the close code is safe to surface
    doAssert err.msg.find("secret") == -1
  doAssert failed

block never_completing_renew_fails_closed_and_aborts_transport:
  # config cadence (30s) but a renew RPC that never completes; the watchdog races
  # it against the short (2s) lease expiry and fails closed, aborting transport.
  let h = newHarness(coordination = pendingRenewCoordination())
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  let abortsBefore = h.driver.abortCount
  discard h.pumpUntil(proc(): bool {.raises: [].} = runFut.finished)
  var failed = false
  try:
    waitFor runFut
  except GatewayShardRunnerError as err:
    failed = true
    doAssert err.msg.find("lease") != -1
    doAssert err.msg.find("secret") == -1
  doAssert failed
  doAssert h.driver.abortCount > abortsBefore # transport aborted -> dispatch stops
  doAssert h.tl.nowMs <= 4_000 # failed around the 2s TTL, not the 30s cadence

block short_ttl_renews_before_expiry_despite_long_interval:
  # TTL (2s) is far shorter than the cadence (30s); renewal must key off the TTL,
  # keeping ownership alive rather than letting it lapse.
  renewCount = 0
  let h = newHarness(coordination = shortTtlLongIntervalCoordination())
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  for _ in 0 ..< 40:
    h.tl.advance(500)
    waitFor sleepAsync(0.milliseconds)
  doAssert renewCount >= 3 # renewed repeatedly within TTL windows
  doAssert not runFut.finished # still owns the shard, no fail-closed
  waitFor h.runner.close()
  waitFor runFut

block never_completing_read_before_expiry_fails_closed:
  let h = newHarness(coordination = shortTtlPendingReadCoordination())
  let runFut = h.runner.run()
  discard h.pumpUntil(proc(): bool {.raises: [].} = runFut.finished)
  var failed = false
  try:
    waitFor runFut
  except GatewayShardRunnerError as err:
    failed = true
    doAssert err.msg.find("session read") != -1
  doAssert failed
  doAssert h.driver.connectUrls.len == 0 # never connected on a lapsed lease

block never_completing_write_is_bounded_by_expiry_and_fails_closed:
  # A checkpoint write that never completes must be bounded by the lease expiry
  # (~3s here after a renew), not the much larger configured budget (7.5s), and a
  # timed-out ambiguous write fails closed rather than retrying on the same token.
  let h = newHarness(coordination = pendingWriteCoordination())
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  let abortsBefore = h.driver.abortCount
  discard h.pumpUntil(proc(): bool {.raises: [].} = runFut.finished)
  var failed = false
  try:
    waitFor runFut
  except GatewayShardRunnerError as err:
    failed = true
    doAssert err.msg.find("checkpoint") != -1 or err.msg.find("lease") != -1
  doAssert failed
  doAssert h.driver.abortCount > abortsBefore
  doAssert h.tl.nowMs <= 4_000 # bounded near the TTL, not the 7.5s write budget

block close_bounds_a_never_completing_release:
  # A release RPC that never completes must not hang close; the bounded release
  # timer fires and close still returns.
  let h = newHarness(coordination = pendingReleaseCoordination())
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  let closeFut = h.runner.close()
  discard h.pumpUntil(proc(): bool {.raises: [].} = closeFut.finished)
  waitFor closeFut
  waitFor runFut

block stale_lease_is_refused_at_dispatch_admission:
  # A dispatch queued before a stall past the TTL must not be admitted or
  # sequenced: the reader/watchdog fail closed instead of dispatching as a stale
  # owner.
  let h = newHarness(coordination = pendingRenewCoordination())
  h.probe.target = 1
  let runFut = h.runner.run()
  discard h.handshakeAfterHello(45_000)
  h.driver.push(dispatchEvent(7, "MESSAGE_CREATE"))
  h.tl.advance(2_500) # past the 2_000 ms lease TTL
  discard h.pumpUntil(proc(): bool {.raises: [].} = runFut.finished)
  var failed = false
  try:
    waitFor runFut
  except GatewayShardRunnerError:
    failed = true
  doAssert failed
  doAssert h.probe.processed.len == 0 # never delivered as a stale owner
  let snap = h.runner.sessionSnapshot
  doAssert snap.sequence.isNone or snap.sequence.get.toInt64 != 7 # no advance to 7

echo "tgateway_shard_runner: all blocks passed"
