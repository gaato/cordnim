import std/[assertions, json]

import cordnim/interactions/exchange
import cordnim/interactions/response_codec
import cordnim/interactions/responder

block reply_is_safe_and_ephemeral_when_requested:
  let encoded = ContextResponse(
    action: raReply,
    visibility: vEphemeral,
    body: %*{"content": "hello", "flags": 32}
  ).initialResponseJson()

  doAssert encoded["type"].getInt() == 4
  doAssert encoded["data"]["flags"].getInt() == 96
  doAssert encoded["data"]["allowed_mentions"]["parse"].len == 0

block defer_and_update_use_distinct_callback_types:
  let deferred = ContextResponse(
    action: raDefer,
    visibility: vEphemeral,
    body: newJNull()
  ).initialResponseJson()
  let updated = ContextResponse(
    action: raUpdateMessage,
    visibility: vPublic,
    body: %*{"content": "updated"}
  ).initialResponseJson()

  doAssert deferred["type"].getInt() == 5
  doAssert deferred["data"]["flags"].getInt() == 64
  doAssert updated["type"].getInt() == 7

block modal_remains_typed_as_an_initial_callback:
  let encoded = ContextResponse(
    action: raModal,
    visibility: vPublic,
    body: %*{"custom_id": "example", "title": "Example"}
  ).initialResponseJson()

  doAssert encoded["type"].getInt() == 9
  doAssert encoded["data"]["custom_id"].getStr() == "example"

block webhook_actions_are_rejected_at_the_callback_boundary:
  doAssertRaises ResponseCodecError:
    discard ContextResponse(
      action: raFollowup,
      visibility: vPublic,
      body: %*{"content": "later"}
    ).initialResponseJson()
