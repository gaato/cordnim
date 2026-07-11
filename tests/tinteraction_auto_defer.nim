import std/unittest

import chronos

import cordnim/interactions
import cordnim/rest/chronos_driver

var sentKind: InitialResponseKind

proc fakeSender(kind: InitialResponseKind,
                visibility: Visibility): Future[void]
                {.gcsafe, raises: [].} =
  sentKind = kind
  let future = newFuture[void]("fake.ack.sender")
  future.complete()
  future

suite "automatic interaction acknowledgement":
  test "defer claims a fresh interaction after its threshold":
    proc scenario(): Future[InteractionResponseState] {.async.} =
      let now = monotonicMillis()
      let responder = newInteractionResponder(now, ackWindowMs = 1_000)
      await responder.autoDeferTask(
        ikApplicationCommand,
        autoDefer(afterMs = 0, visibility = vEphemeral),
        fakeSender
      )
      return responder.state
    check waitFor(scenario()) == irDeferred
    check sentKind == irkDeferredMessage

  test "handler response wins the atomic race":
    proc scenario(): Future[InteractionResponseState] {.async.} =
      let now = monotonicMillis()
      let responder = newInteractionResponder(now, ackWindowMs = 1_000)
      let claim = responder.beginInitial(now)
      discard claim.claim.commit(irkMessage)
      await responder.autoDeferTask(
        ikApplicationCommand,
        autoDefer(afterMs = 0),
        fakeSender
      )
      return responder.state
    check waitFor(scenario()) == irResponded
