## Deterministic event-loop-owned command cooldowns.
##
## A store owns both per-command rules and live expiry entries. Its monotonic
## clock is injected, and `tryAcquire` mutates synchronously, so two command
## dispatches on one event loop cannot both acquire the same key.

import std/[hashes, options, tables]

import cordnim/app
import cordnim/core/ids
import ./spec

type
  CooldownScope* = enum ## Principal that shares a cooldown entry.
    cdsGlobal, ## Every invocation of the command shares one entry.
    cdsUser, ## Each invoking user has an independent entry.
    cdsGuild ## Each guild has an independent entry.

  CooldownRule* = object ## Duration and sharing scope for one command.
    durationMs*: int64 ## Positive cooldown duration in monotonic milliseconds.
    scope*: CooldownScope ## Principal used to partition entries.

  CooldownClock* = proc(): int64 {.closure, raises: [].}
    ## Injected monotonic millisecond source.

  CooldownAcquireKind* = enum ## Result of attempting one cooldown acquisition.
    cakNotConfigured, ## The command has no cooldown rule.
    cakAcquired, ## A new cooldown entry was recorded.
    cakCoolingDown, ## A live entry already exists.
    cakScopeUnavailable ## The invocation cannot supply the configured scope.

  CooldownAcquireResult* = object ## Acquisition result and retry duration.
    kind*: CooldownAcquireKind ## Classification of the attempt.
    retryAfterMs*: int64 ## Remaining time only for `cakCoolingDown`.

  CooldownKey = object
    command: CommandKey
    scope: CooldownScope
    subject: uint64

  CooldownStore* = ref object ## Mutable rules and entries for one event loop.
    clock: CooldownClock
    rules: Table[CommandKey, CooldownRule]
    expiresAt: Table[CooldownKey, int64]

func hash(key: CooldownKey): Hash =
  var value = hash(key.command)
  value = value !& hash(ord(key.scope))
  value = value !& hash(key.subject)
  !$value

func `==`(left, right: CooldownKey): bool =
  left.command == right.command and left.scope == right.scope and
    left.subject == right.subject

proc initCooldownRule*(durationMs: int64,
                       scope = cdsUser): CooldownRule =
  ## Creates a validated cooldown rule.
  if durationMs <= 0:
    raise newException(ValueError,
      "command cooldown duration must be greater than zero")
  CooldownRule(durationMs: durationMs, scope: scope)

proc newCooldownStore*(clock: CooldownClock): CooldownStore =
  ## Creates an empty cooldown store using an explicit monotonic clock.
  if clock.isNil:
    raise newException(ValueError, "command cooldown clock is required")
  CooldownStore(
    clock: clock,
    rules: initTable[CommandKey, CooldownRule](),
    expiresAt: initTable[CooldownKey, int64]()
  )

proc configure*(store: CooldownStore; command: CommandKey;
                rule: CooldownRule) =
  ## Adds or replaces the cooldown rule for `command`.
  if store.isNil:
    raise newException(ValueError, "command cooldown store is required")
  if rule.durationMs <= 0:
    raise newException(ValueError,
      "command cooldown duration must be greater than zero")
  store.rules[command] = rule

proc removeRule*(store: CooldownStore; command: CommandKey) =
  ## Removes a rule and every live entry belonging to the command.
  if store.isNil:
    return
  store.rules.del(command)
  var removals: seq[CooldownKey]
  for key in store.expiresAt.keys:
    if key.command == command:
      removals.add(key)
  for key in removals:
    store.expiresAt.del(key)

proc purgeExpired*(store: CooldownStore; nowMs: int64): int =
  ## Removes expired entries and returns how many were removed.
  if store.isNil:
    return 0
  var removals: seq[CooldownKey]
  for key, expiresAt in store.expiresAt.pairs:
    if expiresAt <= nowMs:
      removals.add(key)
  for key in removals:
    store.expiresAt.del(key)
  removals.len

func cooldownKey(invocation: CommandInvocation; rule: CooldownRule):
    Option[CooldownKey] =
  var subject = 0'u64
  case rule.scope
  of cdsGlobal:
    discard
  of cdsUser:
    subject = invocation.userId.toUint64
  of cdsGuild:
    if invocation.guildId.isNone:
      return none(CooldownKey)
    subject = invocation.guildId.get().toUint64
  some(CooldownKey(
    command: invocation.key, scope: rule.scope, subject: subject))

func saturatingExpiry(nowMs, durationMs: int64): int64 =
  if nowMs > high(int64) - durationMs: high(int64) else: nowMs + durationMs

proc tryAcquire*(store: CooldownStore; invocation: CommandInvocation):
    CooldownAcquireResult =
  ## Atomically checks and records one command cooldown on its owning loop.
  if store.isNil:
    raise newException(ValueError, "command cooldown store is required")
  let command = invocation.key
  if not store.rules.hasKey(command):
    return CooldownAcquireResult(kind: cakNotConfigured)
  let nowMs = store.clock()
  if nowMs < 0:
    raise newException(ValueError,
      "command cooldown clock must not return a negative value")
  discard store.purgeExpired(nowMs)
  let rule = store.rules[command]
  let key = invocation.cooldownKey(rule)
  if key.isNone:
    return CooldownAcquireResult(kind: cakScopeUnavailable)
  let concrete = key.get()
  if store.expiresAt.hasKey(concrete):
    return CooldownAcquireResult(
      kind: cakCoolingDown,
      retryAfterMs: store.expiresAt[concrete] - nowMs
    )
  store.expiresAt[concrete] = saturatingExpiry(nowMs, rule.durationMs)
  CooldownAcquireResult(kind: cakAcquired)

proc reset*(store: CooldownStore; invocation: CommandInvocation): bool =
  ## Removes the live entry selected by `invocation`, if configured and present.
  if store.isNil or not store.rules.hasKey(invocation.key):
    return false
  let key = invocation.cooldownKey(store.rules[invocation.key])
  if key.isNone or not store.expiresAt.hasKey(key.get()):
    return false
  store.expiresAt.del(key.get())
  true

proc clear*(store: CooldownStore) =
  ## Removes every live cooldown while keeping configured rules.
  if not store.isNil:
    store.expiresAt.clear()

proc activeCount*(store: CooldownStore): int =
  ## Purges expired entries and returns the number of live cooldowns.
  if store.isNil:
    return 0
  let nowMs = store.clock()
  if nowMs < 0:
    raise newException(ValueError,
      "command cooldown clock must not return a negative value")
  discard store.purgeExpired(nowMs)
  store.expiresAt.len

proc cooldownMiddleware*[S](
    store: CooldownStore;
    name = "cooldowns";
): CommandMiddleware[S] =
  ## Creates middleware that rejects configured commands until their entry ends.
  ##
  ## Register authorization/check middleware before this middleware when a
  ## rejected authorization attempt should not consume a cooldown entry.
  if store.isNil:
    raise newException(ValueError, "command cooldown store is required")
  if name.len == 0:
    raise newException(ValueError, "command cooldown middleware needs a name")
  result = CommandMiddleware[S](name: name)
  result.before = proc(
      services: ref S;
      invocation: var CommandInvocation,
  ): MiddlewareDecision =
    discard services
    let acquired = store.tryAcquire(invocation)
    case acquired.kind
    of cakNotConfigured, cakAcquired:
      continueDispatch()
    of cakCoolingDown:
      stopDispatch(rejected(
        "command is on cooldown; retry in " & $acquired.retryAfterMs & " ms"))
    of cakScopeUnavailable:
      stopDispatch(rejected(
        "command cooldown requires a guild invocation"))
