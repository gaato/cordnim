## Transport-independent interaction classification and response pumping.
##
## Every delivery adapter runs this classifier and, for handler-driven
## interactions, the same select-then-retain pump. Only the final delivery
## confirmation differs between HTTP and Gateway, so the callback body and the
## response-authority machinery are identical on both transports.

import std/[json, options]

import chronos

import cordnim/core/errors
import cordnim/core/ids
import cordnim/rest/chronos_driver
import cordnim/runtime/task_scope
import ./[exchange, responder, response_codec]

const InitialResponseSendMarginMs* = 250'i64
  ## Time reserved for JSON serialization and the HTTP or Gateway write after a
  ## router selects an initial response.

type
  InteractionClass* = enum ## Transport-independent interaction classification.
    icPing, ## Discord endpoint-verification ping (Discord type 1).
    icCommand, ## Application command invocation (Discord type 2).
    icComponent, ## Message-component activation (Discord type 3).
    icAutocomplete, ## Command-option autocomplete request (Discord type 4).
    icModalSubmit, ## Submitted modal form (Discord type 5).
    icUnknown ## A type this runtime version does not classify.

  SelectedResponse* = object ## A selected callback body plus its delivery
                             ## authority.
    body*: JsonNode ## Serialized Discord interaction callback.
    deliveryValue: InitialDeliveryAuthority ## Confirm-or-unknown delivery
      ## authority; `nil` for a ping. The underlying exchange is deliberately
      ## not exposed through this capability.

  InitialDeliveryAuthority = ref object ## Narrow ingress capability for one
    ## selected callback's transport outcome.
    exchangeValue: InteractionExchange

  RetainedFailureObserver* = proc(interactionId: Option[InteractionId])
    {.gcsafe, raises: [].} ## Receives a redacted correlation ID when an
    ## interaction application boundary fails, including retained post-ACK
    ## tails and autocomplete handlers. Never receives exception messages,
    ## tokens, custom IDs, or body contents.

func `$`(authority: InitialDeliveryAuthority): string =
  ## Renders the delivery capability as an opaque token, never its exchange.
  if authority.isNil: "InitialDeliveryAuthority(none)"
  else: "InitialDeliveryAuthority(capability)"

func repr(authority: InitialDeliveryAuthority): string {.used.} =
  ## Safe debug rendering that never traverses the underlying exchange.
  $authority

proc `%`(authority: InitialDeliveryAuthority): JsonNode =
  ## Serializes the capability as an opaque marker.
  newJString(if authority.isNil: "none" else: "capability")

proc toJsonHook(authority: InitialDeliveryAuthority): JsonNode {.used.} =
  ## Redacts delivery authorities serialized through `std/jsonutils`.
  %authority

func `$`*(response: SelectedResponse): string =
  ## Renders the callback body but keeps the delivery capability opaque.
  ##
  ## The body is the Discord callback (type and data) and carries no credential;
  ## the delivery authority is never traversed into its exchange or sender.
  "SelectedResponse(body: " &
    (if response.body.isNil: "none" else: $response.body) &
    ", delivery: " & $response.deliveryValue & ")"

func repr*(response: SelectedResponse): string =
  ## Safe debug rendering that never reaches the delivery authority's exchange.
  $response

proc `%`*(response: SelectedResponse): JsonNode =
  ## Serializes the token-free callback body and an opaque delivery marker.
  result = newJObject()
  result["body"] =
    if response.body.isNil: newJNull() else: response.body.copy()
  result["delivery"] = %response.deliveryValue

proc toJsonHook*(response: SelectedResponse): JsonNode =
  ## Redacts selected responses serialized through `std/jsonutils`.
  %response

func classify*(interaction: JsonNode): InteractionClass =
  ## Classifies a verified interaction payload without decoding its data.
  ##
  ## Both delivery adapters call this exactly once, so a ping bypasses every
  ## application handler through the same shared classifier the other kinds use.
  if interaction.isNil or interaction.kind != JObject:
    return icUnknown
  let typeNode = interaction.getOrDefault("type")
  if typeNode.isNil or typeNode.kind != JInt:
    return icUnknown
  case typeNode.getInt()
  of 1: icPing
  of 2: icCommand
  of 3: icComponent
  of 4: icAutocomplete
  of 5: icModalSubmit
  else: icUnknown

func pingResponse*(): SelectedResponse =
  ## Builds the callback that answers a Discord endpoint-verification ping.
  ##
  ## A ping carries no response authority, so `delivery` stays `nil` and both
  ## adapters treat its delivery as unconditionally confirmed.
  SelectedResponse(body: %*{"type": 1}, deliveryValue: nil)

proc confirmInitialDelivery(authority: InitialDeliveryAuthority) {.
    gcsafe, raises: [].} =
  ## Confirms that ingress delivered the selected callback.
  if not authority.isNil:
    authority.exchangeValue.confirmInitialDelivery()

proc markInitialDeliveryUnknown(authority: InitialDeliveryAuthority) {.
    gcsafe, raises: [].} =
  ## Seals the callback when ingress cannot determine its delivery outcome.
  if not authority.isNil:
    authority.exchangeValue.markInitialDeliveryUnknown()

proc observedInteractionId*(interaction: JsonNode): Option[InteractionId] =
  ## Extracts a correlation ID for redacted observability, if one is present.
  if interaction.isNil or interaction.kind != JObject:
    return none(InteractionId)
  let idNode = interaction{"id"}
  if idNode.isNil or idNode.kind != JString:
    return none(InteractionId)
  try:
    some(parseId(InteractionId, idNode.getStr()))
  except ValueError:
    none(InteractionId)

proc selectedFromExchange*(exchange: InteractionExchange): SelectedResponse =
  ## Serializes the response one caller selected on `exchange`.
  SelectedResponse(
    body: exchange.selectedInitial().initialResponseJson(),
    deliveryValue: InitialDeliveryAuthority(exchangeValue: exchange))

func hasDelivery(response: SelectedResponse): bool {.used.} =
  ## Reports whether a transport outcome must be recorded.
  not response.deliveryValue.isNil

func deliveryAuthority(response: SelectedResponse): InitialDeliveryAuthority {.used.} =
  ## Returns the private adapter capability.
  response.deliveryValue

proc confirmDelivery(response: SelectedResponse) {.used, gcsafe, raises: [].} =
  response.deliveryValue.confirmInitialDelivery()

proc markDeliveryUnknown(response: SelectedResponse) {.
    used, gcsafe, raises: [].} =
  response.deliveryValue.markInitialDeliveryUnknown()

proc observeRetainedTail(apply: Future[void],
                         observer: RetainedFailureObserver,
                         interactionId: Option[InteractionId]): Future[void] {.
                         async: (raises: []).} =
  ## Retains a handler that already selected a response until its post-ack tail
  ## finishes, redacting any failure to a stable correlation ID.
  try:
    await apply
  except CancelledError:
    # Scope shutdown is an expected lifecycle event, not a handler failure.
    discard
  except CatchableError:
    if not observer.isNil:
      observer(interactionId)

proc pumpApplication*(exchange: InteractionExchange,
                      responder: InteractionResponder,
                      apply: Future[void],
                      tasks: TaskScope,
                      observer: RetainedFailureObserver,
                      interactionId: Option[InteractionId]):
                      Future[SelectedResponse] {.async.} =
  ## Races a handler against its own response selection and the ACK deadline.
  ##
  ## `apply` must select exactly one initial response on `exchange` and then
  ## raise on failure; it never leaks application detail. As soon as a response
  ## is selected this returns its body and transfers the still-running tail to
  ## `tasks`, so a deferred handler's later edits run after delivery instead of
  ## deadlocking on the delivery receipt. On every early exit the losing operand
  ## and the deadline timer are cancelled, so no future is orphaned.
  var retained = false
  var timer: Future[void]
  let selection = exchange.waitInitialSelection()
  try:
    let delay = max(0'i64,
      responder.remainingAckMs(monotonicMillis()) - InitialResponseSendMarginMs)
    timer = sleepAsync(delay.milliseconds)
    discard await race(
      FutureBase(apply), FutureBase(selection), FutureBase(timer))

    if exchange.initialResponseReady:
      let selected = exchange.selectedFromExchange()
      if tasks.isClosed:
        # Shutdown may seal the scope while an in-flight dispatch is selecting
        # its response. Join locally so the handler cannot escape, while the
        # already-selected delivery authority remains valid for ingress.
        await apply.cancelAndWait()
      else:
        discard tasks.spawn(
          observeRetainedTail(apply, observer, interactionId))
      retained = true
      return selected

    if apply.finished:
      # A normal return always selects, so an unselected finish means the
      # handler raised. Re-raising preserves the already-redacted error type.
      await apply
      raise newException(InteractionExchangeError,
        "interaction handler produced no response")

    raise newDiscordError(InteractionExpiredError,
      "interaction acknowledgement deadline expired before a response")
  finally:
    if not timer.isNil:
      await timer.cancelAndWait()
    await selection.cancelAndWait()
    if not retained:
      await apply.cancelAndWait()
