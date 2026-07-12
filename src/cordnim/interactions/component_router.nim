## Stateless typed routing for persistent Discord message components.
##
## The router authenticates `custom_id` before selecting a route, decodes the
## versioned payload into its Nim action type, and invokes an ordinary Chronos
## handler. No process-local collector is needed, so registered buttons survive
## restarts as long as signing keys and migration decoders remain available.
##
## A component activation is an interaction, so it flows through the same
## response model as an application command: one `InteractionExchange` owns the
## single initial response, and a narrow `Context` exposes `reply`, `defer`,
## `update message`, `show modal`, `edit original`, and `follow-up`. A handler
## may still return a `ComponentResponse`; that value is selected only
## when the handler did not already choose one through the context.

import std/[json, options, tables]

import chronos

import cordnim/app/context as appcontext
import cordnim/api/messages
import cordnim/components/[forms, routes, typed_routes]
import cordnim/rest/chronos_driver
import cordnim/rest/request
import cordnim/runtime/task_scope
import ./[context, exchange, responder,
  response_codec, router]
import ./dispatch_core {.all.}
import ./envelope {.all.}

type
  ComponentRouteDispatchError* = object of CatchableError ## Malformed,
    ## unauthenticated, expired, or unregistered component route.

  ComponentResponseKind* = enum ## Initial callback produced by a typed
    ## component handler.
    crkMessage, ## Send a new interaction message (callback type 4).
    crkUpdateMessage, ## Update the component's source message (type 7).
    crkModal, ## Present a modal (callback type 9).
    crkContext ## The handler already selected its response through the context.

  ComponentResponse* = object ## Transport-neutral immediate component response.
    kind*: ComponentResponseKind ## Discord callback semantic.
    data*: JsonNode ## Message or modal callback data; nil for `crkContext`.

  ComponentInvocation* = object ## Verified message-component interaction
    ## supplied to handlers.
    context*: InvocationContext ## Installation owner and effective permissions.
    componentType*: int ## Raw Discord component type number.
    values*: seq[string] ## Select values, empty for buttons.
    resolved*: JsonNode ## Lossless resolved entity maps.
    snapshot*: InteractionSnapshot ## Token-free view of the interaction. Its
      ## `rawJson` returns an owned, redacted copy, replacing the former raw
      ## interaction escape hatch that exposed the credential.

  ComponentCtx*[S] = object ## Typed application services, a response context,
    ## and verified component invocation metadata.
    serviceValue: ref S
    responseContextValue: appcontext.Context
    invocationValue: ComponentInvocation

  ComponentHandler*[S, T] = proc(context: ComponentCtx[S], action: T):
    Future[ComponentResponse] {.closure, gcsafe, raises: [].} ## Handler for one
    ## decoded typed action.

  ErasedComponentHandler[S] = proc(services: ref S,
    exchange: InteractionExchange, responseContext: appcontext.Context,
    invocation: ComponentInvocation, envelope: RouteEnvelope):
    Future[void] {.closure, gcsafe,
      raises: [CancelledError, ComponentRouteDispatchError].}

  ComponentRouter*[S] = ref object ## Typed persistent route registry using one
    ## shared HMAC key ring and one structured task scope.
    services: ref S ## App-owned dependency container, held by reference.
    envelopeValue: RouteCodec ## Shared HMAC verification and rotation config.
    handlers: Table[uint16, ErasedComponentHandler[S]]
    tasks: TaskScope ## Owns retained post-acknowledgement handler tails.
    senderFactory: InteractionSenderFactory ## Builds one envelope-owned
      ## post-acknowledgement sender per interaction; no payload is retained.
    failureObserver: RetainedFailureObserver ## Redacted background-failure sink.

func `$`*(invocation: ComponentInvocation): string =
  ## Metadata-only rendering; values, resolved entities, and snapshot raw JSON
  ## are deliberately excluded.
  "ComponentInvocation(type: " & $invocation.componentType &
    ", " & $invocation.snapshot & ")"

func repr*(invocation: ComponentInvocation): string =
  $invocation

proc `%`*(invocation: ComponentInvocation): JsonNode =
  %*{
    "componentType": invocation.componentType,
    "interaction": %invocation.snapshot
  }

proc toJsonHook*(invocation: ComponentInvocation): JsonNode =
  %invocation

func `$`*[S](context: ComponentCtx[S]): string =
  ## Never traverses application services or response authority.
  "ComponentCtx(invocation: " & $context.invocationValue & ")"

func repr*[S](context: ComponentCtx[S]): string =
  $context

proc `%`*[S](context: ComponentCtx[S]): JsonNode =
  %*{"invocation": %context.invocationValue}

proc toJsonHook*[S](context: ComponentCtx[S]): JsonNode =
  %context

proc replyComponent*(data: sink JsonNode): ComponentResponse =
  ## Creates a new-message response to a component activation.
  if data.isNil or data.kind != JObject:
    raise newException(ValueError, "component response data must be an object")
  ComponentResponse(kind: crkMessage, data: data)

proc updateComponent*(data: sink JsonNode): ComponentResponse =
  ## Creates a source-message update response.
  if data.isNil or data.kind != JObject:
    raise newException(ValueError, "component response data must be an object")
  ComponentResponse(kind: crkUpdateMessage, data: data)

proc showRawComponentModal*(data: sink JsonNode): ComponentResponse =
  ## Creates a modal response through the explicit caller-built JSON path.
  if data.isNil or data.kind != JObject:
    raise newException(ValueError, "modal response data must be an object")
  ComponentResponse(kind: crkModal, data: data)

proc showComponentModal*(spec: ModalSpec): ComponentResponse =
  ## Validates and creates a modal response from a `ModalSpec`.
  let problems = spec.validate()
  if problems.len > 0:
    raise newException(ValueError,
      "modal schema is invalid: " & problems[0])
  showRawComponentModal(spec.toJson())

func respondedViaContext*(): ComponentResponse =
  ## Signals that the handler already selected its response through the context.
  ##
  ## Return this after using `reply`, `deferReply`, `updateMessage`,
  ## `showModal`, `editOriginal`, or `followup`; the router then treats the
  ## context selection as authoritative and ignores this value.
  ComponentResponse(kind: crkContext, data: nil)

func componentVisibility(data: JsonNode): Visibility =
  # Discord carries component-message visibility in the message flags, so the
  # response stays public here and the caller's `flags` bit is preserved.
  if not data.isNil and data.kind == JObject and data.hasKey("flags") and
      data["flags"].kind == JInt and (data["flags"].getInt() and 64) != 0:
    vEphemeral
  else:
    vPublic

func toContextResponse(response: ComponentResponse): ContextResponse =
  ## Maps a returned component response to a transport-neutral context action.
  case response.kind
  of crkMessage:
    ContextResponse(action: raReply, visibility: response.data.componentVisibility(),
      body: response.data)
  of crkUpdateMessage:
    ContextResponse(action: raUpdateMessage, visibility: vPublic,
      body: response.data)
  of crkModal:
    ContextResponse(action: raModal, visibility: vPublic, body: response.data)
  of crkContext:
    ContextResponse(action: raReply, visibility: vPublic, body: nil)

proc selectComponentResponse*(exchange: InteractionExchange,
                              response: ComponentResponse) =
  ## Selects a returned component or modal response on the exchange.
  ##
  ## Does nothing when the handler already selected a response through the
  ## context. Raises `InteractionExchangeError` if the handler neither returned
  ## a response nor selected one, or if the response is illegal for the
  ## interaction type. The modal router reuses this so both share one selection
  ## rule and one interaction-type policy check.
  if exchange.initialResponseReady:
    return
  if response.kind == crkContext:
    raise newException(InteractionExchangeError,
      "handler returned no response and selected none through the context")
  let contextResponse = response.toContextResponse()
  contextResponse.validateInitialResponse()
  exchange.selectInitial(contextResponse)

func envelope*[S](router: ComponentRouter[S]): RouteCodec =
  ## Returns the shared signing envelope so a modal router can reuse the ring.
  router.envelopeValue

proc newComponentRouterWithSenderFactory[S](
    services: ref S, envelope: sink RouteCodec,
    senderFactory: InteractionSenderFactory,
    failureObserver: RetainedFailureObserver = nil): ComponentRouter[S] =
  ## Creates an empty persistent router around one signing-key ring.
  ##
  ## `services` is the application-owned allocation, held by reference so
  ## handlers observe exactly the services the application owns. `senderFactory`
  ## builds each interaction's original-message edit and follow-up sender from the
  ## ingress envelope's credentials; `failureObserver` receives a redacted
  ## correlation ID if a retained handler tail fails after delivery.
  if services.isNil:
    raise newException(ValueError, "component router requires app services")
  if envelope.signer.isNil:
    raise newException(ValueError, "component router requires an HMAC signer")
  ComponentRouter[S](
    services: services,
    envelopeValue: envelope,
    handlers: initTable[uint16, ErasedComponentHandler[S]](),
    tasks: newTaskScope(),
    senderFactory: senderFactory,
    failureObserver: failureObserver
  )

proc newComponentRouter*[S](services: ref S, envelope: sink RouteCodec,
                            failureObserver: RetainedFailureObserver = nil):
                            ComponentRouter[S] =
  ## Creates a credential-blind router for direct tests and custom selection.
  newComponentRouterWithSenderFactory(
    services, envelope, nil, failureObserver)

proc register*[S, T](router: ComponentRouter[S], codec: TypedRouteCodec[T],
                     handler: ComponentHandler[S, T]) =
  ## Registers one stable route type and its typed migration decoders.
  ##
  ## The typed codec must use the router's key ring, and its route type must be
  ## unique; both are rejected explicitly so a misconfiguration fails at wiring
  ## time rather than during dispatch.
  if router.isNil:
    raise newException(ValueError, "component router is nil")
  if handler.isNil:
    raise newException(ValueError, "component route handler is nil")
  if codec.envelope.activeKeyId != router.envelopeValue.activeKeyId or
      codec.envelope.keys != router.envelopeValue.keys:
    raise newException(ValueError,
      "typed route codec does not use the component router key ring")
  if router.handlers.hasKey(codec.routeTypeId):
    raise newException(ValueError,
      "duplicate component route type ID " & $codec.routeTypeId)

  let typedCodec = codec
  let typedHandler = handler
  let erased: ErasedComponentHandler[S] = proc(
      services: ref S, exchange: InteractionExchange,
      responseContext: appcontext.Context, invocation: ComponentInvocation,
      envelope: RouteEnvelope): Future[void]
      {.gcsafe, raises: [CancelledError, ComponentRouteDispatchError].} =
    # This closure is the single explicit component-application boundary. It
    # decodes, runs the handler, and selects the returned response, translating
    # every application failure into a redacted dispatch error that never
    # carries the exception message, body, token, or custom_id contents.
    proc apply(): Future[void] {.
        async: (raises: [CancelledError, ComponentRouteDispatchError]).} =
      let decoded = typedCodec.decodeVerified(envelope)
      if not decoded.ok:
        raise newException(ComponentRouteDispatchError,
          "component route payload could not be decoded")
      let ctx = ComponentCtx[S](
        serviceValue: services,
        responseContextValue: responseContext,
        invocationValue: invocation)
      var response: ComponentResponse
      try:
        response = await typedHandler(ctx, decoded.value)
      except CancelledError:
        raise
      except CatchableError:
        raise newException(ComponentRouteDispatchError,
          "component route handler failed")
      try:
        selectComponentResponse(exchange, response)
      except CancelledError:
        raise
      except CatchableError:
        raise newException(ComponentRouteDispatchError,
          "component response could not be selected")
    {.cast(gcsafe).}:
      return apply()
  router.handlers[codec.routeTypeId] = erased

proc decodeInvocation(interaction: JsonNode): ComponentInvocation =
  if interaction.kind != JObject or not interaction.hasKey("type") or
      interaction["type"].kind != JInt or interaction["type"].getInt() != 3:
    raise newException(ComponentRouteDispatchError,
      "interaction is not a message component activation")
  if not interaction.hasKey("data") or interaction["data"].kind != JObject:
    raise newException(ComponentRouteDispatchError,
      "component interaction data is missing")
  let data = interaction["data"]
  if not data.hasKey("component_type") or
      data["component_type"].kind != JInt:
    raise newException(ComponentRouteDispatchError,
      "component interaction type is missing")

  result.context = interaction.invocationContext()
  result.componentType = data["component_type"].getInt()
  result.resolved = if data.hasKey("resolved"):
    data["resolved"]
  else:
    newJObject()
  if data.hasKey("values"):
    if data["values"].kind != JArray:
      raise newException(ComponentRouteDispatchError,
        "component values must be an array")
    for value in data["values"]:
      if value.kind != JString:
        raise newException(ComponentRouteDispatchError,
          "component values must be strings")
      result.values.add(value.getStr())

proc selectResponse[S](router: ComponentRouter[S],
                        ingress: InteractionEnvelope,
                        nowUnixSeconds: int64, receivedAt: MonoMillis):
                        Future[SelectedResponse] {.async.} =
  ## Authenticates, decodes, and dispatches a component activation.
  ##
  ## The ingress envelope owns the credentials and the preconstructed sender.
  ## Decoding runs over its token-free copy; the handler receives only a
  ## token-free `InteractionSnapshot`. Returns the selected callback body and the
  ## exchange that owns delivery authority; the calling adapter confirms delivery
  ## only after its own write succeeds. `nowUnixSeconds` bounds route expiry;
  ## `receivedAt` anchors the acknowledgement deadline.
  if router.isNil:
    raise newException(ValueError, "component router is nil")
  let decoding = ingress.decodingJson()
  var invocation = decoding.decodeInvocation()
  invocation.snapshot = ingress.snapshot()
  let data = decoding["data"]
  if not data.hasKey("custom_id") or data["custom_id"].kind != JString:
    raise newException(ComponentRouteDispatchError,
      "component custom_id is missing")
  let decoded = router.envelopeValue.decodeRoute(
    data["custom_id"].getStr(), nowUnixSeconds)
  if not decoded.ok:
    raise newException(ComponentRouteDispatchError,
      "component custom_id authentication failed")
  if not router.handlers.hasKey(decoded.envelope.routeTypeId):
    raise newException(ComponentRouteDispatchError,
      "component route type is not registered")

  let responder = newInteractionResponder(receivedAt)
  let exchange = newInteractionExchange(
    ikMessageComponent,
    invocation.context.responsePolicy,
    responder,
    invocation.context.followupBudget,
    ingress.postAckSender())
  let responseContext = appcontext.newContext(exchange)
  let apply = router.handlers[decoded.envelope.routeTypeId](
    router.services, exchange, responseContext, invocation, decoded.envelope)
  return await pumpApplication(exchange, responder, apply, router.tasks,
    router.failureObserver, ingress.observedInteractionId())

proc selectResponse[S](router: ComponentRouter[S], interaction: JsonNode,
                        nowUnixSeconds: int64, receivedAt: MonoMillis):
                        Future[SelectedResponse] {.async.} =
  ## Forms the ingress envelope for a verified payload, then dispatches it.
  return await router.selectResponse(
    looseInteractionEnvelope(interaction, router.senderFactory),
    nowUnixSeconds, receivedAt)

proc route[S](router: ComponentRouter[S], interaction: JsonNode,
               nowUnixSeconds: int64,
               receivedAt = monotonicMillis()): Future[JsonNode] {.
               used, async.} =
  ## Authenticates, dispatches, and serializes one component callback.
  ##
  ## This result-returning convenience confirms delivery locally and returns the
  ## callback body. Real ingress uses `InteractionDispatcher`, which confirms
  ## delivery only after the transport write succeeds.
  let selected = await router.selectResponse(
    interaction, nowUnixSeconds, receivedAt)
  selected.confirmDelivery()
  return selected.body

proc close*[S](router: ComponentRouter[S]): Future[void] {.
               async: (raises: []).} =
  ## Cancels and joins retained post-acknowledgement handler tails.
  if not router.isNil:
    await router.tasks.cancelAndJoin()

# --- Typed response context conveniences -------------------------------------

func services*[S](context: ComponentCtx[S]): lent S =
  ## Borrows the application dependency container.
  context.serviceValue[]

func invocation*[S](context: ComponentCtx[S]): lent ComponentInvocation =
  ## Borrows the verified component invocation.
  context.invocationValue

func responseContext*[S](context: ComponentCtx[S]): appcontext.Context =
  ## Returns the ingress-owned response-capable interaction context.
  context.responseContextValue

proc reply*[S](context: ComponentCtx[S], body: sink JsonNode,
               visibility = vPublic): Future[void] =
  ## Selects an immediate new-message response to the component.
  appcontext.reply(context.responseContextValue, body, visibility)

proc reply*[S](context: ComponentCtx[S], content: string,
               visibility = vPublic): Future[void] =
  ## Selects a plain-content new-message response to the component.
  appcontext.reply(context.responseContextValue, content, visibility)

proc reply*[S](context: ComponentCtx[S], draft: MessageDraft[V2];
               visibility = vPublic;
               allowedMentions = initAllowedMentions()): Future[void] =
  ## Selects a validated Components V2 response to the component.
  appcontext.reply(context.responseContextValue, draft, visibility,
    allowedMentions)

proc deferReply*[S](context: ComponentCtx[S], visibility = vPublic): Future[void] =
  ## Selects a deferred new message so later edits or follow-ups are legal.
  appcontext.deferReply(context.responseContextValue, visibility)

proc deferUpdate*[S](context: ComponentCtx[S]): Future[void] =
  ## Selects a deferred component-message update (callback type 6).
  appcontext.deferReply(context.responseContextValue, vPublic, update = true)

proc updateMessage*[S](context: ComponentCtx[S], body: sink JsonNode):
    Future[void] =
  ## Selects an immediate update of the component's source message.
  appcontext.updateMessage(context.responseContextValue, body)

proc updateMessage*[S](context: ComponentCtx[S], draft: MessageDraft[V2];
                       allowedMentions = initAllowedMentions()): Future[void] =
  ## Updates or upgrades the component's source message to Components V2.
  appcontext.updateMessage(context.responseContextValue, draft,
    allowedMentions)

proc showModal*[S](context: ComponentCtx[S], spec: ModalSpec): Future[void] =
  ## Validates and selects a modal as the component's initial response.
  appcontext.showModal(context.responseContextValue, spec)

proc showRawModal*[S](context: ComponentCtx[S], body: sink JsonNode):
    Future[void] =
  ## Selects caller-built modal JSON through the explicit low-level path.
  appcontext.showRawModal(context.responseContextValue, body)

proc editOriginal*[S](context: ComponentCtx[S], body: sink JsonNode):
    Future[void] =
  ## Waits for confirmed initial delivery, then edits the original response.
  appcontext.editOriginal(context.responseContextValue, body)

proc editOriginal*[S](context: ComponentCtx[S], draft: MessageDraft[V2];
                      allowedMentions = initAllowedMentions()): Future[void] =
  ## Edits or upgrades the original response to Components V2.
  appcontext.editOriginal(context.responseContextValue, draft,
    allowedMentions)

proc followup*[S](context: ComponentCtx[S], body: sink JsonNode,
                  visibility = vPublic): Future[void] =
  ## Waits for confirmed initial delivery, then sends a follow-up message.
  appcontext.followup(context.responseContextValue, body, visibility)

proc followup*[S](context: ComponentCtx[S], draft: MessageDraft[V2];
                  visibility = vPublic;
                  allowedMentions = initAllowedMentions()): Future[void] =
  ## Sends a validated Components V2 follow-up.
  appcontext.followup(context.responseContextValue, draft, visibility,
    allowedMentions)
