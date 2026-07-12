import std/[assertions, json, options]

import chronos

import cordnim/interactions/[context, exchange, responder]
import cordnim/rest/chronos_driver

func invocation(budget = none(int)): InvocationContext =
  InvocationContext(
    followupBudget: budget,
    responsePolicy: ResponsePolicy(publicResponseAllowed: true)
  )

proc completeNow(): Future[void] {.raises: [].} =
  result = newFuture[void]("cordnim.exchange.test-complete")
  result.complete()

block selection_and_delivery_are_distinct:
  var sent = 0
  let sender: ContextResponseSender = proc (
      response: ContextResponse
    ): Future[void] {.closure, gcsafe, raises: [].} =
    doAssert response.action == raFollowup
    doAssert response.body{"content"}.getStr() == "after"
    inc sent
    completeNow()
  let exchange = newInteractionExchange(
    ikApplicationCommand, invocation(some(1)), monotonicMillis(), sender)

  var initialBody = %*{"content": "ready"}
  exchange.selectInitial(ContextResponse(
    action: raReply,
    visibility: vPublic,
    body: initialBody
  ))
  initialBody["content"] = %"mutated after selection"
  let selected = waitFor exchange.initialResponse()
  doAssert selected.body["content"].getStr() == "ready"
  selected.body["content"] = %"mutated returned copy"
  doAssert waitFor(exchange.initialResponse()).body["content"].getStr() ==
    "ready"
  doAssert exchange.initialResponseReady
  doAssert exchange.responseState == irInitialPending
  doAssert not exchange.deliveryReceipt().finished

  var followupBody = %*{"content": "after"}
  let followup = exchange.sendAfterDelivery(ContextResponse(
    action: raFollowup,
    visibility: vPublic,
    body: followupBody
  ))
  followupBody["content"] = %"mutated while awaiting delivery"
  doAssert not followup.finished
  doAssert sent == 0

  exchange.confirmInitialDelivery()
  waitFor followup
  doAssert exchange.responseState == irResponded
  doAssert exchange.deliveryReceipt().finished
  doAssert sent == 1

  doAssertRaises InteractionExchangeError:
    waitFor exchange.sendAfterDelivery(ContextResponse(
      action: raFollowup,
      visibility: vPublic,
      body: %*{"content": "over budget"}
    ))
  doAssert sent == 1

block ambiguous_delivery_unblocks_waiters_with_an_error:
  let exchange = newInteractionExchange(
    ikApplicationCommand, invocation(), monotonicMillis())
  exchange.selectInitial(ContextResponse(
    action: raDefer,
    visibility: vEphemeral,
    body: newJNull()
  ))
  let edit = exchange.sendAfterDelivery(ContextResponse(
    action: raEditOriginal,
    visibility: vPublic,
    body: %*{"content": "never sent"}
  ))
  exchange.markInitialDeliveryUnknown()
  doAssert exchange.responseState == irTransportUnknown
  doAssertRaises InteractionDeliveryUnknownError:
    waitFor edit

block duplicate_selection_is_rejected_by_one_authority:
  let exchange = newInteractionExchange(
    ikApplicationCommand, invocation(), monotonicMillis())
  exchange.selectInitial(ContextResponse(
    action: raReply,
    visibility: vPublic,
    body: %*{}
  ))
  doAssertRaises InteractionExchangeError:
    exchange.selectInitial(ContextResponse(
      action: raModal,
      visibility: vPublic,
      body: %*{"custom_id": "duplicate"}
    ))

block cancelled_waiters_do_not_cancel_shared_delivery_authority:
  let exchange = newInteractionExchange(
    ikApplicationCommand, invocation(), monotonicMillis())
  exchange.selectInitial(ContextResponse(
    action: raReply,
    visibility: vPublic,
    body: %*{"content": "selected"}
  ))

  let receipt = exchange.deliveryReceipt()
  waitFor receipt.cancelAndWait()
  doAssert receipt.cancelled

  let postAckWaiter = exchange.sendAfterDelivery(ContextResponse(
    action: raEditOriginal,
    visibility: vPublic,
    body: %*{"content": "cancelled waiter"}
  ))
  waitFor postAckWaiter.cancelAndWait()
  doAssert postAckWaiter.cancelled

  # Closing/cancelling every waiter before ingress confirms must not consume
  # or cancel the exchange-owned receipt.
  exchange.confirmInitialDelivery()
  waitFor exchange.deliveryReceipt()
  doAssert exchange.responseState == irResponded

block initial_action_is_the_only_response_kind_authority:
  let exchange = newInteractionExchange(
    ikApplicationCommand, invocation(), monotonicMillis())
  doAssertRaises InteractionExchangeError:
    exchange.selectInitial(ContextResponse(
      action: raAutocomplete,
      visibility: vPublic,
      body: %*{"choices": []}
    ))

  let another = newInteractionExchange(
    ikApplicationCommand, invocation(), monotonicMillis())
  doAssertRaises InteractionExchangeError:
    another.selectInitial(ContextResponse(
      action: raEditOriginal,
      visibility: vPublic,
      body: %*{}
    ))
