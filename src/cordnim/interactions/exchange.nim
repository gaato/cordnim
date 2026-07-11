## One interaction's response authority, delivery receipt, and follow-up port.
##
## Selecting an initial response and delivering it are deliberately separate.
## HTTP ingress must return the selected body before its socket write can be
## observed; post-ack operations wait for the delivery receipt instead of
## overtaking that write.

import std/[atomics, json, options]

import chronos

import cordnim/rest/[chronos_driver, request]
import ./[context, responder]

type
  ResponseAction* = enum ## Transport-neutral operation selected by a handler.
    raReply, ## Select an immediate initial message.
    raDefer, ## Select a deferred initial message response.
    raDeferUpdate, ## Select a deferred component-message update.
    raUpdateMessage, ## Select an immediate component-message update.
    raModal, ## Select a modal as the initial response.
    raEditOriginal, ## Edit the original response after delivery.
    raFollowup ## Create a follow-up message after delivery.

  ContextResponse* = object ## One response operation at the transport port.
    action*: ResponseAction ## Semantic operation selected by the handler.
    visibility*: Visibility ## Visibility after installation-policy coercion.
    body*: JsonNode ## Discord message, update, or modal data.

  ContextResponseSender* = proc (
      response: ContextResponse
    ): Future[void] {.closure, gcsafe, raises: [CatchableError].}
    ## Caller-owned post-acknowledgement transport I/O.

  InteractionExchangeError* = object of CatchableError
    ## Invalid selection, delivery, or post-acknowledgement operation.

  InteractionDeliveryUnknownError* = object of InteractionExchangeError
    ## The initial response may have left the process but was not confirmed.

  InteractionExchange* = ref object ## Single response authority for an
                                     ## interaction.
    kindValue: InteractionType
    responsePolicy: ResponsePolicy
    responderValue: InteractionResponder
    selectedFuture: Future[ContextResponse]
    deliveredFuture: Future[void]
    selectedClaim: InitialResponseClaim
    selectedKind: InitialResponseKind
    postAckSender: ContextResponseSender
    followupsRemaining: Atomic[int]

func responseErrorMessage(error: InteractionResponseError): string =
  case error
  of ireNone:
    "no interaction response error"
  of ireAlreadyAcknowledged:
    "the interaction was already acknowledged"
  of ireInitialDeadlineExpired:
    "the interaction acknowledgement deadline expired"
  of ireTokenExpired:
    "the interaction token expired"
  of ireClaimNotPending:
    "the initial response claim is no longer pending"
  of irePolicyUnsupported:
    "the interaction does not support this response"

proc failExchange(message: string) {.noinline, noreturn.} =
  raise newException(InteractionExchangeError, message)

proc newInteractionExchange*(interactionType: InteractionType,
                             policy: ResponsePolicy,
                             responder: InteractionResponder,
                             followupBudget: Option[int],
                             postAckSender: ContextResponseSender = nil):
                             InteractionExchange =
  ## Creates an exchange around ingress-owned response authority.
  if responder.isNil:
    raise newException(ValueError, "interaction response authority is required")
  if followupBudget.isSome and followupBudget.get() < 0:
    raise newException(ValueError, "interaction follow-up budget is negative")
  new result
  result.kindValue = interactionType
  result.responsePolicy = policy
  result.responderValue = responder
  result.postAckSender = postAckSender
  result.selectedFuture = newFuture[ContextResponse](
    "cordnim.interactions.response-selected")
  result.deliveredFuture = newFuture[void](
    "cordnim.interactions.response-delivered")
  result.followupsRemaining.store(
    if followupBudget.isSome: followupBudget.get() else: -1)

proc newInteractionExchange*(interactionType: InteractionType,
                             invocation: InvocationContext,
                             receivedAt: MonoMillis,
                             postAckSender: ContextResponseSender = nil):
                             InteractionExchange =
  ## Creates a fresh exchange from verified invocation policy.
  newInteractionExchange(
    interactionType,
    invocation.responsePolicy,
    newInteractionResponder(receivedAt),
    invocation.followupBudget,
    postAckSender)

func interactionType*(exchange: InteractionExchange): InteractionType =
  ## Returns the interaction class whose response rules apply.
  exchange.kindValue

proc responseState*(exchange: InteractionExchange):
                    InteractionResponseState =
  ## Loads the authoritative response state.
  exchange.responderValue.state()

func effectiveVisibility*(exchange: InteractionExchange,
                          requested: Visibility): Visibility =
  ## Applies the immutable policy derived by verified ingress.
  if requested == vPublic and
      not exchange.responsePolicy.publicResponseAllowed:
    vEphemeral
  else:
    requested

func initialResponse*(exchange: InteractionExchange):
                      Future[ContextResponse] =
  ## Returns the future completed when one caller selects the initial response.
  exchange.selectedFuture

func deliveryReceipt*(exchange: InteractionExchange): Future[void] =
  ## Returns the future completed only after transport delivery is confirmed.
  exchange.deliveredFuture

proc selectInitial*(exchange: InteractionExchange,
                    response: sink ContextResponse,
                    responseKind: InitialResponseKind) =
  ## Atomically selects one initial response without claiming delivery.
  if exchange.isNil:
    failExchange("interaction response exchange is unavailable")
  if responseKind notin exchange.kindValue.allowedInitialKinds:
    failExchange(irePolicyUnsupported.responseErrorMessage())

  let claim = exchange.responderValue.beginInitial(monotonicMillis())
  if not claim.ok:
    failExchange(claim.error.responseErrorMessage())

  exchange.selectedClaim = claim.claim
  exchange.selectedKind = responseKind
  exchange.selectedFuture.complete(response)

proc confirmInitialDelivery*(exchange: InteractionExchange) {.
    gcsafe, raises: [].} =
  ## Commits a selected response after the transport confirms its write.
  if exchange.isNil or exchange.selectedClaim.isNil or
      exchange.deliveredFuture.finished:
    return
  let committed = exchange.selectedClaim.commit(exchange.selectedKind)
  if committed.ok:
    exchange.deliveredFuture.complete()
  else:
    exchange.deliveredFuture.fail(newException(InteractionExchangeError,
      committed.error.responseErrorMessage()))

proc markInitialDeliveryUnknown*(exchange: InteractionExchange) {.
    gcsafe, raises: [].} =
  ## Seals a selected response when transport delivery is ambiguous.
  if exchange.isNil or exchange.selectedClaim.isNil or
      exchange.deliveredFuture.finished:
    return
  discard exchange.selectedClaim.markTransportUnknown()
  exchange.deliveredFuture.fail(newException(
    InteractionDeliveryUnknownError,
    "initial interaction response delivery is unknown"))

proc reserveFollowup(exchange: InteractionExchange): bool =
  var remaining = exchange.followupsRemaining.load(moAcquire)
  while remaining >= 0:
    if remaining == 0:
      return false
    var expected = remaining
    if exchange.followupsRemaining.compareExchange(
        expected, remaining - 1, moAcquireRelease, moAcquire):
      return true
    remaining = expected
  true

proc sendAfterDelivery*(exchange: InteractionExchange,
                        response: ContextResponse): Future[void] {.async.} =
  ## Waits for confirmed ACK delivery, then uses the post-ACK transport port.
  if exchange.isNil:
    failExchange("interaction response exchange is unavailable")
  if response.action notin {raEditOriginal, raFollowup}:
    failExchange("initial response must be selected through selectInitial")

  await exchange.deliveredFuture
  let permitted = exchange.responderValue.canFollowup(monotonicMillis())
  if not permitted.ok:
    failExchange(permitted.error.responseErrorMessage())
  if exchange.postAckSender.isNil:
    failExchange("post-acknowledgement response transport is not configured")
  if response.action == raFollowup and not exchange.reserveFollowup():
    failExchange("interaction follow-up budget is exhausted")

  # A non-idempotent follow-up reservation remains consumed when transport
  # outcome is unknown; restoring it could create a sixth Discord follow-up.
  await exchange.postAckSender(response)
