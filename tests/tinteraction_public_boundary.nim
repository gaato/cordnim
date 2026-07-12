## Compile-time checks for the handler-visible interaction surface.

import std/unittest

import cordnim/interactions
import cordnim/core/[ids, secrets]

suite "interaction public boundary":
  test "credential owners and delivery authority are not public API":
    check not compiles((block:
      var envelope: InteractionEnvelope
      discard envelope))
    check not compiles((block:
      var factory: InteractionSenderFactory
      discard factory))
    check not compiles(looseInteractionEnvelope(nil))
    check not compiles(interactionWebhookSender(nil, default(ApplicationId),
      default(Secret[InteractionToken])))
    check not compiles(SelectedResponse().delivery)
