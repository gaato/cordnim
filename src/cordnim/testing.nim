## Deterministic testing infrastructure for Cordnim applications.
##
## This is the public facade for the testing kit. It re-exports in-process
## harnesses and scripted transports that exercise the real REST, Gateway, and
## command contracts without opening sockets, reading the wall clock, consuming
## real entropy, or touching the filesystem. Production entry modules never
## import these helpers.
##
## The kit provides: `TestDiscordApp` (command harness), `ManualClock`/
## `FakeClock` (manual clock), `FixedEntropy` (deterministic bytes and nonces),
## `ScriptedRestTransport` and `ScriptedGatewayDriver` (scripted transport and
## driver contracts), representative interaction/Gateway `fixtures`, canonical
## JSON comparison, configurable credential redaction, record/replay cassette
## primitives, and a teardown report for outstanding work.

import cordnim/testing/all

export all

runnableExamples:
  import std/json

  # A manually advanced clock keeps deadline and cache tests deterministic.
  var clock = initManualClock(1_000)
  clock.advance(250)
  doAssert clock.nowMs == 1_250

  # A fixed entropy source replaces real randomness and fails loudly if drained.
  var entropy = fixedEntropyFromString("nonce-bytes")
  doAssert entropy.nextHex(3) == "6e6f6e"
  doAssert entropy.remaining == 8

  # Fixture builders return representative, override-friendly Discord payloads.
  let interaction = slashCommandInteraction(name = "ping")
  doAssert interaction["data"]["name"].getStr() == "ping"

  # Canonical comparison ignores object key order.
  doAssert jsonEquiv(%*{"a": 1, "b": 2}, %*{"b": 2, "a": 1})
