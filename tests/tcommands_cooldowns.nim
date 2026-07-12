## Deterministic command cooldown tests.

import std/[json, options, unittest]

import cordnim/[app, commands]
import cordnim/command_policies
import cordnim/core/ids

type CooldownServices = object
  nowMs: int64

proc makeInvocation(user: uint64; guild = none(GuildId)):
    CommandInvocation =
  CommandInvocation(
    kind: ckChatInput,
    name: "limited",
    options: newJObject(),
    userId: toId(UserId, user),
    guildId: guild
  )

suite "Command cooldowns":
  test "partitions user cooldowns and expires on the injected clock":
    var nowMs = 100'i64
    let store = newCooldownStore(proc(): int64 = nowMs)
    store.configure(initCommandKey(ckChatInput, "limited"),
      initCooldownRule(500, cdsUser))

    let first = makeInvocation(1)
    let other = makeInvocation(2)
    check store.tryAcquire(first).kind == cakAcquired
    let blocked = store.tryAcquire(first)
    check blocked.kind == cakCoolingDown
    check blocked.retryAfterMs == 500
    check store.tryAcquire(other).kind == cakAcquired
    check store.activeCount == 2

    nowMs = 600
    check store.tryAcquire(first).kind == cakAcquired
    check store.activeCount == 1

  test "global scope shares one entry and reset releases it":
    var nowMs = 0'i64
    let store = newCooldownStore(proc(): int64 = nowMs)
    store.configure(initCommandKey(ckChatInput, "limited"),
      initCooldownRule(1_000, cdsGlobal))
    let first = makeInvocation(1)
    let second = makeInvocation(2)
    check store.tryAcquire(first).kind == cakAcquired
    check store.tryAcquire(second).kind == cakCoolingDown
    check store.reset(first)
    check store.tryAcquire(second).kind == cakAcquired

  test "guild scope fails explicitly outside a guild":
    var nowMs = 0'i64
    let store = newCooldownStore(proc(): int64 = nowMs)
    store.configure(initCommandKey(ckChatInput, "limited"),
      initCooldownRule(1_000, cdsGuild))
    check store.tryAcquire(makeInvocation(1)).kind == cakScopeUnavailable

  test "middleware returns a stable retry result":
    var nowMs = 10'i64
    let store = newCooldownStore(proc(): int64 = nowMs)
    store.configure(initCommandKey(ckChatInput, "limited"),
      initCooldownRule(250, cdsUser))
    let middleware = cooldownMiddleware[CooldownServices](store)
    var services: ref CooldownServices
    new services
    var request = makeInvocation(4)
    check middleware.before(services, request).kind == mdContinue
    let stopped = middleware.before(services, request)
    check stopped.kind == mdStop
    check stopped.result.kind == crRejected
    check stopped.result.message ==
      "command is on cooldown; retry in 250 ms"
