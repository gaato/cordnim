## Restart-safe typed routing for Discord modal submissions.
##
## A modal submission is authenticated exactly like a persistent component: the
## modal's root `custom_id` is a signed, versioned route produced by the same
## `RouteCodec` key ring, so submissions survive restarts and signing-key
## rotation with no process-local state. Registration binds a stable route
## type/version (the typed route codec that recovers the modal's route state), a
## modal decoder that turns submit data into a typed value while accumulating
## validation problems and unknown fields, and an async typed handler.
##
## Authentication happens before any submission decoding. The signed route type
## is authoritative for modal identity, so the redundant plaintext `WrongModal`
## check performed by a derived form decoder is stripped after decoding.

import std/[json, options, tables]

import chronos

import cordnim/app/context as appcontext
import cordnim/components/forms
import cordnim/components/[routes, typed_routes]
import cordnim/rest/chronos_driver
import cordnim/rest/request
import cordnim/runtime/task_scope
import ./[component_router, context, dispatch_core, exchange, responder, router]

export ComponentResponse, ComponentResponseKind, replyComponent, updateComponent,
  respondedViaContext

type
  ModalRouteDispatchError* = object of CatchableError ## Malformed,
    ## unauthenticated, expired, unregistered, or wrong-type modal submission.

  ModalOrigin* = enum ## Interaction that originally presented the modal.
    moApplicationCommand, ## A command opened the modal; no source message.
    moMessageComponent ## A component opened it from an existing message.

  ModalInvocation* = object ## Verified modal submission supplied to handlers.
    context*: InvocationContext ## Installation owner and effective permissions.
    origin*: ModalOrigin ## Whether update-style callbacks are legal.
    resolved*: JsonNode ## Lossless resolved-entity maps from submit data.
    raw*: JsonNode ## Complete interaction for raw escape hatches.

  ModalCtx*[S] = object ## Typed application services, a response context, and
    ## verified modal submission metadata.
    serviceValue: ref S
    responseContextValue: appcontext.Context
    invocationValue: ModalInvocation

  ModalFormDecoder*[F] = proc(data: JsonNode, hooks: ModalDecodeHooks):
    ModalDecodeResult[F] {.gcsafe, raises: [CatchableError].} ## Decodes submit
    ## data into a typed form value, accumulating problems and unknown fields.
    ## Pass `proc(d, h) = decodeDiscordModal(MyForm, d, h)`.

  ModalHandler*[S, R, F] = proc(context: ModalCtx[S], route: R,
    form: ModalDecodeResult[F]): Future[ComponentResponse]
    {.closure, gcsafe, raises: [].} ## Handler receiving the recovered route
    ## state and the decoded submission, including any validation problems.

  ErasedModalHandler[S] = proc(services: ref S,
    exchange: InteractionExchange, responseContext: appcontext.Context,
    invocation: ModalInvocation, envelope: RouteEnvelope, data: JsonNode):
    Future[void] {.closure, gcsafe,
      raises: [CancelledError, ModalRouteDispatchError].}

  ModalRouter*[S] = ref object ## Typed persistent modal registry sharing the
    ## component key ring and response model.
    services: ref S ## App-owned dependency container, held by reference.
    envelopeValue: RouteCodec ## Shared HMAC verification and rotation config.
    handlers: Table[uint16, ErasedModalHandler[S]]
    hooks: ModalDecodeHooks ## Resolved-entity decode extension points.
    tasks: TaskScope ## Owns retained post-acknowledgement handler tails.
    postAckSink: PostAckResponseSink ## Original-message edit and follow-up I/O.
    failureObserver: RetainedFailureObserver ## Redacted background-failure sink.

func envelope*[S](router: ModalRouter[S]): RouteCodec =
  ## Returns the shared signing envelope.
  router.envelopeValue

proc newModalRouter*[S](services: ref S, envelope: sink RouteCodec,
                        postAckSink: PostAckResponseSink = nil,
                        failureObserver: RetainedFailureObserver = nil,
                        hooks = initModalDecodeHooks()): ModalRouter[S] =
  ## Creates an empty modal router around one signing-key ring.
  ##
  ## Reusing the component router's `envelope` keeps one signing scheme for both
  ## component and modal routes. `services` is the app-owned allocation, held by
  ## reference so handlers observe exactly the services the application owns.
  if services.isNil:
    raise newException(ValueError, "modal router requires app services")
  if envelope.signer.isNil:
    raise newException(ValueError, "modal router requires an HMAC signer")
  ModalRouter[S](
    services: services,
    envelopeValue: envelope,
    handlers: initTable[uint16, ErasedModalHandler[S]](),
    hooks: hooks,
    tasks: newTaskScope(),
    postAckSink: postAckSink,
    failureObserver: failureObserver
  )

proc stripRedundantWrongModal[F](decoded: var ModalDecodeResult[F]) =
  # The signed route type already authenticated the modal identity, so a derived
  # form decoder's plaintext custom_id mismatch is expected and not a real
  # problem. Every other accumulated problem and unknown field is preserved.
  var kept: seq[ModalDecodeProblem]
  for problem in decoded.problems:
    if problem.kind != ModalDecodeProblemKind.WrongModal:
      kept.add problem
  decoded.problems = kept

proc register*[S, R, F](router: ModalRouter[S], codec: TypedRouteCodec[R],
                        decoder: ModalFormDecoder[F],
                        handler: ModalHandler[S, R, F]) =
  ## Binds one stable route type, a modal decoder, and a typed handler.
  ##
  ## The typed codec must use the router's key ring, and its route type must be
  ## unique; both are rejected explicitly. A submitted custom_id whose signed
  ## route type does not match this registration fails as `WrongModal` at
  ## dispatch, so a wrong modal can never silently reach the handler.
  if router.isNil:
    raise newException(ValueError, "modal router is nil")
  if decoder.isNil:
    raise newException(ValueError, "modal form decoder is nil")
  if handler.isNil:
    raise newException(ValueError, "modal route handler is nil")
  if codec.envelope.activeKeyId != router.envelopeValue.activeKeyId or
      codec.envelope.keys != router.envelopeValue.keys:
    raise newException(ValueError,
      "typed route codec does not use the modal router key ring")
  if router.handlers.hasKey(codec.routeTypeId):
    raise newException(ValueError,
      "duplicate modal route type ID " & $codec.routeTypeId)

  let typedCodec = codec
  let typedDecoder = decoder
  let typedHandler = handler
  let routerHooks = router.hooks
  let erased: ErasedModalHandler[S] = proc(
      services: ref S, exchange: InteractionExchange,
      responseContext: appcontext.Context, invocation: ModalInvocation,
      envelope: RouteEnvelope, data: JsonNode): Future[void]
      {.gcsafe, raises: [CancelledError, ModalRouteDispatchError].} =
    # Single explicit modal-application boundary: authenticate the route state,
    # decode the form, run the handler, and select the response, redacting every
    # failure so no exception message, body, token, or custom_id leaks.
    proc apply(): Future[void] {.
        async: (raises: [CancelledError, ModalRouteDispatchError]).} =
      let routeState = typedCodec.decodeVerified(envelope)
      if not routeState.ok:
        raise newException(ModalRouteDispatchError,
          "modal submission custom_id does not match a registered modal")
      var form: ModalDecodeResult[F]
      try:
        form = typedDecoder(data, routerHooks)
      except CancelledError:
        raise
      except CatchableError:
        raise newException(ModalRouteDispatchError,
          "modal submission could not be decoded")
      form.stripRedundantWrongModal()
      let ctx = ModalCtx[S](
        serviceValue: services,
        responseContextValue: responseContext,
        invocationValue: invocation)
      var response: ComponentResponse
      try:
        response = await typedHandler(ctx, routeState.value, form)
      except CancelledError:
        raise
      except CatchableError:
        raise newException(ModalRouteDispatchError,
          "modal route handler failed")
      try:
        selectComponentResponse(exchange, response)
      except CancelledError:
        raise
      except CatchableError:
        raise newException(ModalRouteDispatchError,
          "modal response could not be selected")
    {.cast(gcsafe).}:
      return apply()
  router.handlers[codec.routeTypeId] = erased

proc decodeInvocation(interaction: JsonNode):
    tuple[invocation: ModalInvocation, data: JsonNode, customId: string] =
  if interaction.kind != JObject or not interaction.hasKey("type") or
      interaction["type"].kind != JInt or interaction["type"].getInt() != 5:
    raise newException(ModalRouteDispatchError,
      "interaction is not a modal submission")
  if not interaction.hasKey("data") or interaction["data"].kind != JObject:
    raise newException(ModalRouteDispatchError,
      "modal submission data is missing")
  let data = interaction["data"]
  if not data.hasKey("custom_id") or data["custom_id"].kind != JString:
    raise newException(ModalRouteDispatchError,
      "modal submission custom_id is missing")
  result.customId = data["custom_id"].getStr()
  result.data = data
  var origin = moApplicationCommand
  if interaction.hasKey("message"):
    if interaction["message"].kind != JObject:
      raise newException(ModalRouteDispatchError,
        "modal submission message must be an object")
    origin = moMessageComponent
  result.invocation = ModalInvocation(
    context: interaction.invocationContext(),
    origin: origin,
    resolved: if data.hasKey("resolved"): data["resolved"] else: newJObject(),
    raw: interaction)

proc postAckSender[S](router: ModalRouter[S],
                      interaction: JsonNode): ContextResponseSender =
  result = proc(response: ContextResponse): Future[void] {.
      closure, gcsafe, raises: [CatchableError].} =
    if router.postAckSink.isNil:
      raise newException(InteractionExchangeError,
        "modal post-acknowledgement transport is not configured")
    {.cast(gcsafe).}:
      return router.postAckSink(interaction, response)

proc selectResponse*[S](router: ModalRouter[S], interaction: JsonNode,
                        nowUnixSeconds: int64, receivedAt: MonoMillis):
                        Future[SelectedResponse] {.async.} =
  ## Authenticates, decodes, and dispatches a modal submission.
  ##
  ## Authentication of the signed route runs before submission decoding. Returns
  ## the selected callback body and the exchange that owns delivery authority;
  ## the calling adapter confirms delivery only after its own write succeeds.
  if router.isNil:
    raise newException(ValueError, "modal router is nil")
  let decoded = interaction.decodeInvocation()
  let route = router.envelopeValue.decodeRoute(decoded.customId, nowUnixSeconds)
  if not route.ok:
    raise newException(ModalRouteDispatchError,
      "modal submission custom_id authentication failed")
  if not router.handlers.hasKey(route.envelope.routeTypeId):
    raise newException(ModalRouteDispatchError,
      "modal route type is not registered")

  let responder = newInteractionResponder(receivedAt)
  let exchange = newInteractionExchange(
    if decoded.invocation.origin == moMessageComponent:
      ikComponentModalSubmit
    else:
      ikCommandModalSubmit,
    decoded.invocation.context.responsePolicy,
    responder,
    decoded.invocation.context.followupBudget,
    router.postAckSender(interaction))
  let responseContext = appcontext.newContext(exchange)
  let apply = router.handlers[route.envelope.routeTypeId](
    router.services, exchange, responseContext, decoded.invocation,
    route.envelope, decoded.data)
  return await pumpApplication(exchange, responder, apply, router.tasks,
    router.failureObserver, interaction.observedInteractionId())

proc route*[S](router: ModalRouter[S], interaction: JsonNode,
               nowUnixSeconds: int64,
               receivedAt = monotonicMillis()): Future[JsonNode] {.async.} =
  ## Authenticates, dispatches, and serializes one modal callback.
  ##
  ## This result-returning convenience confirms delivery locally and returns the
  ## callback body. Real ingress uses `InteractionDispatcher`.
  let selected = await router.selectResponse(
    interaction, nowUnixSeconds, receivedAt)
  selected.delivery.confirmInitialDelivery()
  return selected.body

proc close*[S](router: ModalRouter[S]): Future[void] {.
               async: (raises: []).} =
  ## Cancels and joins retained post-acknowledgement handler tails.
  if not router.isNil:
    await router.tasks.cancelAndJoin()

proc routedModalSpec*[R](codec: TypedRouteCodec[R], state: R, spec: ModalSpec,
                         expiresAt: int64): ModalSpec =
  ## Builds a validated modal whose `custom_id` is a signed, expiring route.
  ##
  ## Pass the result to the standard `showModal` or `showComponentModal` path.
  ## The matching `ModalRouter` authenticates the submission and recovers
  ## `state`. Raises `ValueError` when the resulting schema is invalid.
  result = spec
  result.customId = codec.encode(state, expiresAt)
  let problems = result.validate()
  if problems.len > 0:
    raise newException(ValueError,
      "routed modal schema is invalid: " & problems[0])

proc routedModalJson*[R](codec: TypedRouteCodec[R], state: R, spec: ModalSpec,
                         expiresAt: int64): JsonNode =
  ## Serializes a routed modal for the explicit raw-JSON response path.
  ##
  ## Prefer `routedModalSpec` with `showModal`. This helper remains for low-level
  ## codecs and should be passed to `showRawModal`.
  routedModalSpec(codec, state, spec, expiresAt).toJson()

# --- Typed response context conveniences -------------------------------------

func services*[S](context: ModalCtx[S]): lent S =
  ## Borrows the application dependency container.
  context.serviceValue[]

func invocation*[S](context: ModalCtx[S]): lent ModalInvocation =
  ## Borrows the verified modal submission.
  context.invocationValue

func responseContext*[S](context: ModalCtx[S]): appcontext.Context =
  ## Returns the ingress-owned response-capable interaction context.
  context.responseContextValue

proc reply*[S](context: ModalCtx[S], body: sink JsonNode,
               visibility = vPublic): Future[void] =
  ## Selects an immediate new-message response to the submission.
  appcontext.reply(context.responseContextValue, body, visibility)

proc reply*[S](context: ModalCtx[S], content: string,
               visibility = vPublic): Future[void] =
  ## Selects a plain-content new-message response to the submission.
  appcontext.reply(context.responseContextValue, content, visibility)

proc deferReply*[S](context: ModalCtx[S], visibility = vPublic): Future[void] =
  ## Selects a deferred new message so later edits or follow-ups are legal.
  appcontext.deferReply(context.responseContextValue, visibility)

proc deferUpdate*[S](context: ModalCtx[S]): Future[void] =
  ## Selects a deferred update of the message that presented the modal.
  appcontext.deferReply(context.responseContextValue, vPublic, update = true)

proc updateMessage*[S](context: ModalCtx[S], body: sink JsonNode): Future[void] =
  ## Selects an immediate update of the message that presented the modal.
  appcontext.updateMessage(context.responseContextValue, body)

proc editOriginal*[S](context: ModalCtx[S], body: sink JsonNode): Future[void] =
  ## Waits for confirmed initial delivery, then edits the original response.
  appcontext.editOriginal(context.responseContextValue, body)

proc followup*[S](context: ModalCtx[S], body: sink JsonNode,
                  visibility = vPublic): Future[void] =
  ## Waits for confirmed initial delivery, then sends a follow-up message.
  appcontext.followup(context.responseContextValue, body, visibility)
