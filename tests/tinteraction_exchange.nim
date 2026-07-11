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
    inc sent
    completeNow()
  let exchange = newInteractionExchange(
    ikApplicationCommand, invocation(some(1)), monotonicMillis(), sender)

  exchange.selectInitial(ContextResponse(
    action: raReply,
    visibility: vPublic,
    body: %*{"content": "ready"}
  ), irkMessage)
  doAssert exchange.initialResponse.finished
  doAssert exchange.responseState == irInitialPending
  doAssert not exchange.deliveryReceipt.finished

  let followup = exchange.sendAfterDelivery(ContextResponse(
    action: raFollowup,
    visibility: vPublic,
    body: %*{"content": "after"}
  ))
  doAssert not followup.finished
  doAssert sent == 0

  exchange.confirmInitialDelivery()
  waitFor followup
  doAssert exchange.responseState == irResponded
  doAssert exchange.deliveryReceipt.finished
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
  ), irkDeferredMessage)
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
  ), irkMessage)
  doAssertRaises InteractionExchangeError:
    exchange.selectInitial(ContextResponse(
      action: raModal,
      visibility: vPublic,
      body: %*{"custom_id": "duplicate"}
    ), irkModal)
