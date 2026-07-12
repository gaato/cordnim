## Autocomplete interaction dispatch over the command layer's registry.
##
## The command layer owns the autocomplete model end to end: `decodeAutocomplete`
## turns a verified type-4 interaction into a typed `AutocompleteRequest`,
## `AutocompleteRegistry.dispatch` routes it to the option's handler, and
## `autocompleteResponse` serializes the suggestions into a Discord type-8
## callback (at most 25 choices). This module is only the transport bridge that
## runs those command-owned steps behind the shared exchange and delivery model,
## so HTTP and Gateway ingress produce the identical callback body.
##
## Applications register handlers on the dispatcher, which forwards to
## `AutocompleteRegistry.register` with the optional group and subcommand path;
## no command module is edited here.

import std/[json, options]

import chronos

import cordnim/commands
import cordnim/core/errors
import cordnim/rest/[chronos_driver, request]
import ./[context, dispatch_core, exchange, responder, response_codec]

type
  AutocompleteDispatchError* = object of CatchableError
    ## Stable, redacted failure at the autocomplete application boundary.

proc selectAutocomplete*(exchange: InteractionExchange, data: JsonNode) =
  ## Validates and claims the single autocomplete response.
  let response = ContextResponse(
    action: raAutocomplete,
    visibility: vPublic,
    body: data)
  response.validateInitialResponse()
  exchange.selectInitial(response)

proc selectAutocompleteResponse*[S](registry: AutocompleteRegistry[S],
                                    services: ref S, interaction: JsonNode,
                                    receivedAt: MonoMillis,
                                    observer: RetainedFailureObserver = nil):
                                    Future[SelectedResponse] {.async.} =
  ## Decodes, dispatches, serializes, and selects an autocomplete response.
  ##
  ## The dispatcher calls this after classifying a type-4 interaction on either
  ## transport. An empty or unmatched registry yields a valid empty type-8
  ## callback. Decode, handler, and choice-validation failures cross this
  ## boundary only as a redacted `AutocompleteDispatchError`.
  let responder = newInteractionResponder(receivedAt)
  let exchange = newInteractionExchange(
    ikAutocomplete,
    ResponsePolicy(publicResponseAllowed: true),
    responder,
    none(int),
    nil)

  proc apply(): Future[void] {.async.} =
    var request: AutocompleteRequest
    try:
      request = decodeAutocomplete(interaction)
    except CancelledError:
      raise
    except CatchableError:
      raise newException(AutocompleteDispatchError,
        "autocomplete request could not be decoded")

    var choices: seq[AutocompleteChoice]
    try:
      choices = await registry.dispatch(services, request)
    except CancelledError:
      raise
    except CatchableError:
      raise newException(AutocompleteDispatchError,
        "autocomplete handler failed")

    var callback: JsonNode
    try:
      # The request-aware overload validates every choice's value kind against
      # the focused option's declared kind before a callback is built.
      callback = autocompleteResponse(request, choices)
    except CancelledError:
      raise
    except CatchableError:
      raise newException(AutocompleteDispatchError,
        "autocomplete response could not be selected")

    # Re-sample the deadline immediately before selecting. Decode and the handler
    # run synchronously up to their first pending await, so expensive pre-await
    # work can cross the send margin while the deadline timer is blocked on that
    # same event-loop turn and has not yet fired. A crossed margin is an expiry, not
    # an application failure: it is raised as `InteractionExpiredError`, never
    # wrapped as a handler error and never reported to the failure observer.
    if responder.remainingAckMs(monotonicMillis()) <= InitialResponseSendMarginMs:
      raise newDiscordError(InteractionExpiredError,
        "autocomplete acknowledgement send budget was exhausted")

    try:
      exchange.selectAutocomplete(callback["data"])
    except CancelledError:
      raise
    except CatchableError:
      raise newException(AutocompleteDispatchError,
        "autocomplete response could not be selected")

  let observedId = interaction.observedInteractionId()
  let delay = responder.remainingAckMs(monotonicMillis()) -
    InitialResponseSendMarginMs
  if delay <= 0:
    raise newDiscordError(InteractionExpiredError,
      "autocomplete acknowledgement send budget was exhausted")

  let application = apply()
  let timer = sleepAsync(delay.milliseconds)
  try:
    discard await race(FutureBase(application), FutureBase(timer))
    if application.finished:
      try:
        await application
      except AutocompleteDispatchError:
        if not observer.isNil:
          observer(observedId)
        raise
      if not exchange.initialResponseReady:
        raise newException(AutocompleteDispatchError,
          "autocomplete handler produced no response")
      return exchange.selectedFromExchange()

    await application.cancelAndWait()
    raise newDiscordError(InteractionExpiredError,
      "autocomplete acknowledgement deadline expired before a response")
  finally:
    await timer.cancelAndWait()
    if not application.finished:
      await application.cancelAndWait()
