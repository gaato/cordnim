## Response capability supplied to one application-command handler.
##
## Application services and invocation data belong to `CommandCtx`. This
## object contains only the ingress-owned interaction exchange, so copying a
## command context cannot create a second response authority.

import std/json

import chronos

import cordnim/components/forms
import cordnim/api/messages
import cordnim/interactions/[exchange, responder, response_codec]

export exchange

type
  Context* = ref object ## Narrow response capability for one interaction.
    exchangeValue: InteractionExchange

  ContextResponseError* = InteractionExchangeError
    ## Compatibility name for invalid response-state transitions.

proc newContext*(exchange: InteractionExchange): Context =
  ## Creates a response capability around an ingress-owned exchange.
  if exchange.isNil:
    raise newException(ValueError, "interaction exchange is required")
  Context(exchangeValue: exchange)

func contextSummary(context: Context): string =
  ## Metadata-only rendering. A `Context` transitively reaches the exchange's
  ## credential-capturing sender, so no renderer may traverse into it.
  if context.isNil: "Context(nil)"
  else: "Context(interactionType: " & $context.exchangeValue.interactionType & ")"

func `$`*(context: Context): string =
  ## Safe rendering: response authority stays unobservable through a context.
  context.contextSummary()

func repr*(context: Context): string =
  ## Safe debug rendering that never reaches the exchange or its sender.
  context.contextSummary()

proc `%`*(context: Context): JsonNode =
  ## Serializes only the safe interaction-type metadata.
  if context.isNil: newJNull()
  else: %*{"interactionType": $context.exchangeValue.interactionType}

proc toJsonHook*(context: Context): JsonNode =
  ## Redacts contexts serialized through `std/jsonutils`.
  %context

func interactionType*(context: Context): InteractionType =
  ## Returns the Discord interaction class handled by this context.
  if context.isNil:
    raise newException(InteractionExchangeError,
      "interaction response context is unavailable")
  context.exchangeValue.interactionType

proc responseState*(context: Context): InteractionResponseState =
  ## Loads the authoritative initial-response state.
  if context.isNil:
    raise newException(InteractionExchangeError,
      "interaction response context is unavailable")
  context.exchangeValue.responseState()

proc selectInitial(context: Context, action: ResponseAction,
                   body: sink JsonNode,
                   visibility: Visibility): Future[void] {.async.} =
  if context.isNil:
    raise newException(InteractionExchangeError,
      "interaction response context is unavailable")
  let exchange = context.exchangeValue
  let response = ContextResponse(
    action: action,
    visibility: exchange.effectiveVisibility(visibility),
    body: body
  )
  response.validateInitialResponse()
  exchange.selectInitial(response)

proc reply*(context: Context, body: sink JsonNode,
            visibility = vPublic): Future[void] =
  ## Selects the one immediate initial message response.
  ##
  ## Completion means selection succeeded; ingress confirms delivery later.
  context.selectInitial(raReply, body, visibility)

proc reply*(context: Context, content: string,
            visibility = vPublic): Future[void] =
  ## Selects a plain-content initial message response.
  context.reply(%*{"content": content}, visibility)

proc reply*(context: Context, draft: MessageDraft[V2];
            visibility = vPublic;
            allowedMentions = initAllowedMentions()): Future[void] =
  ## Selects a validated Components V2 initial response.
  context.reply(v2Create(draft,
    allowedMentions = allowedMentions).toJson(), visibility)

proc deferReply*(context: Context, visibility = vPublic,
                 update = false): Future[void] =
  ## Selects a deferred response so later edits or follow-ups are legal.
  context.selectInitial(
    if update: raDeferUpdate else: raDefer,
    newJNull(),
    visibility
  )

proc updateMessage*(context: Context, body: sink JsonNode): Future[void] =
  ## Selects an immediate component-message update.
  context.selectInitial(raUpdateMessage, body, vPublic)

proc updateMessage*(context: Context, draft: MessageDraft[V2];
                    allowedMentions = initAllowedMentions()): Future[void] =
  ## Updates or upgrades the component message to Components V2.
  context.updateMessage(v2Edit(draft.v2.children,
    allowedMentions = allowedMentions).toJson())

proc validatedModalBody(spec: ModalSpec): JsonNode =
  let problems = spec.validate()
  if problems.len > 0:
    raise newException(ValueError,
      "modal schema is invalid: " & problems[0])
  spec.toJson()

proc showModal*(context: Context, spec: ModalSpec): Future[void] =
  ## Validates and selects a modal as the initial response.
  context.selectInitial(raModal, spec.validatedModalBody(), vPublic)

proc showRawModal*(context: Context, body: sink JsonNode): Future[void] =
  ## Selects caller-built modal JSON through the explicit low-level path.
  ##
  ## This checks only the callback container shape. Prefer `showModal` with a
  ## `ModalSpec` so component and modal constraints are validated before the
  ## exchange consumes response authority.
  context.selectInitial(raModal, body, vPublic)

proc sendAfterAck(context: Context, action: ResponseAction,
                  body: sink JsonNode,
                  visibility: Visibility): Future[void] {.async.} =
  if context.isNil:
    raise newException(InteractionExchangeError,
      "interaction response context is unavailable")
  let exchange = context.exchangeValue
  await exchange.sendAfterDelivery(ContextResponse(
    action: action,
    visibility: exchange.effectiveVisibility(visibility),
    body: body
  ))

proc editOriginal*(context: Context, body: sink JsonNode): Future[void] =
  ## Waits for confirmed initial delivery, then edits the original response.
  context.sendAfterAck(raEditOriginal, body, vPublic)

proc editOriginal*(context: Context, draft: MessageDraft[V2];
                   allowedMentions = initAllowedMentions()): Future[void] =
  ## Edits or upgrades the original response to Components V2.
  context.editOriginal(v2Edit(draft.v2.children,
    allowedMentions = allowedMentions).toJson())

proc followup*(context: Context, body: sink JsonNode,
               visibility = vPublic): Future[void] =
  ## Waits for confirmed initial delivery, then sends a follow-up.
  context.sendAfterAck(raFollowup, body, visibility)

proc followup*(context: Context, content: string,
               visibility = vPublic): Future[void] =
  ## Sends a plain-content follow-up after confirmed initial delivery.
  context.followup(%*{"content": content}, visibility)

proc followup*(context: Context, draft: MessageDraft[V2];
               visibility = vPublic;
               allowedMentions = initAllowedMentions()): Future[void] =
  ## Sends a validated Components V2 follow-up.
  context.followup(v2Create(draft,
    allowedMentions = allowedMentions).toJson(), visibility)
