## Transport-independent interaction dispatcher.
##
## `InteractionDispatcher` is the one place that classifies an interaction and
## routes it to the command, autocomplete, component, or modal handler. Neither
## transport is special: the HTTP and Gateway adapters both call `dispatch`, so
## decoding, routing, handler execution, and initial-response selection are
## identical, and only the final delivery confirmation differs. The dispatcher
## returns a selected callback plus its delivery authority; it never claims a
## successful write before the transport reports one.

import std/[json, options, times]

import chronos

import cordnim/app
import cordnim/commands
import cordnim/components/[routes, typed_routes]
import cordnim/rest/request
import ./[autocomplete, component_router, dispatch_core, exchange, http_server,
  modal_router, router]

export SelectedResponse, InteractionClass, classify
export router.DeferredCompletionSink, router.DeferredFailureObserver,
  router.PostAckResponseSink, router.InitialResponseSender,
  dispatch_core.RetainedFailureObserver

type
  InteractionDispatchError* = object of CatchableError
    ## An interaction was routed to a handler class that is not configured, or
    ## carried a type this runtime version does not dispatch.

  InteractionDispatcherClosedError* = object of InteractionDispatchError
    ## Registration or dispatch was attempted after shutdown began.

  DispatcherState = enum
    dsOpen
    dsClosing
    dsClosed

  InteractionWallClock* = proc(): int64 {.closure, gcsafe, raises: [].}
    ## Injected Unix-seconds clock used only to authenticate expiring persistent
    ## component and modal routes.

  InteractionDispatcher*[S] = ref object ## Owns and coordinates every typed
                                         ## interaction router for one app.
    ## One Chronos event-loop owner serializes registration, dispatch, and close.
    app: DiscordApp[S]
    commandRouterValue: CommandRouter[S]
    componentRouterValue: ComponentRouter[S]
    modalRouterValue: ModalRouter[S]
    autocompleteRegistryValue: AutocompleteRegistry[S]
    routeClock: InteractionWallClock
    handlerFailureObserver: RetainedFailureObserver
    state: DispatcherState
    closeTask: Future[void]

proc requireOpen[S](dispatcher: InteractionDispatcher[S]) =
  if dispatcher.isNil or dispatcher.app.isNil:
    raise newException(ValueError, "interaction dispatcher is not initialized")
  if dispatcher.state != dsOpen:
    raise newException(InteractionDispatcherClosedError,
      "interaction dispatcher is closed")

proc systemInteractionUnixSeconds*(): int64 {.gcsafe, raises: [].} =
  ## Returns the current wall-clock instant as Unix seconds.
  ##
  ## The dispatcher accepts this operation explicitly so tests and embedders do
  ## not need to alter process time to exercise route expiry.
  getTime().toUnix()

proc newInteractionDispatcher*[S](
    app: DiscordApp[S];
    completionSink: DeferredCompletionSink = nil;
    commandFailureObserver: DeferredFailureObserver = nil;
    postAckSink: PostAckResponseSink = nil;
    handlerFailureObserver: RetainedFailureObserver = nil;
    routeEnvelope = none(RouteCodec);
    routeClock: InteractionWallClock = systemInteractionUnixSeconds):
    InteractionDispatcher[S] =
  ## Creates a dispatcher owning a command router and optional other routers.
  ##
  ## Component and modal routing are enabled by supplying `routeEnvelope`, whose
  ## key ring both routers share so there is one signing scheme. `postAckSink`
  ## carries every interaction class's original-message edits and follow-ups.
  ## `handlerFailureObserver` receives redacted correlation IDs for component,
  ## modal, and autocomplete failures. Autocomplete handlers are added with
  ## `registerAutocomplete`. All routers borrow the app-owned services by
  ## reference; no service container is copied.
  if app.isNil:
    raise newException(ValueError, "interaction dispatcher requires an app")
  if routeClock.isNil:
    raise newException(ValueError,
      "interaction dispatcher route clock is required")
  result = InteractionDispatcher[S](
    app: app,
    commandRouterValue: newCommandRouter(app, completionSink,
      commandFailureObserver, postAckSink),
    autocompleteRegistryValue: initAutocompleteRegistry[S](),
    routeClock: routeClock,
    handlerFailureObserver: handlerFailureObserver,
    state: dsOpen)
  if routeEnvelope.isSome:
    result.componentRouterValue = newComponentRouter(
      app.serviceRef, routeEnvelope.get(), postAckSink, handlerFailureObserver)
    result.modalRouterValue = newModalRouter(
      app.serviceRef, routeEnvelope.get(), postAckSink, handlerFailureObserver)

proc registerComponent*[S, T](dispatcher: InteractionDispatcher[S],
                              codec: TypedRouteCodec[T],
                              handler: ComponentHandler[S, T]) =
  ## Registers a typed persistent component route.
  ##
  ## Raises `ValueError` unless the dispatcher was created with a route envelope.
  dispatcher.requireOpen()
  if dispatcher.componentRouterValue.isNil:
    raise newException(ValueError,
      "component routing requires a dispatcher route envelope")
  dispatcher.componentRouterValue.register(codec, handler)

proc registerModal*[S, R, F](dispatcher: InteractionDispatcher[S],
                             codec: TypedRouteCodec[R],
                             decoder: ModalFormDecoder[F],
                             handler: ModalHandler[S, R, F]) =
  ## Registers a typed restart-safe modal submission route.
  ##
  ## Raises `ValueError` unless the dispatcher was created with a route envelope.
  dispatcher.requireOpen()
  if dispatcher.modalRouterValue.isNil:
    raise newException(ValueError,
      "modal routing requires a dispatcher route envelope")
  dispatcher.modalRouterValue.register(codec, decoder, handler)

proc registerAutocomplete*[S](dispatcher: InteractionDispatcher[S],
                              command: CommandKey, option: string,
                              handler: AutocompleteHandler[S],
                              group = none(string),
                              subcommand = none(string)) =
  ## Registers a focused-option autocomplete handler on its command path.
  ##
  ## Delegates to `AutocompleteRegistry.register`, which rejects a nil handler or
  ## a duplicate command/group/subcommand/option key. An autocomplete
  ## interaction with no matching handler still yields a valid empty type-8
  ## response.
  dispatcher.requireOpen()
  dispatcher.autocompleteRegistryValue.register(
    command, option, handler, group, subcommand)

proc dispatch*[S](dispatcher: InteractionDispatcher[S], interaction: JsonNode,
                  receivedAt: MonoMillis): Future[SelectedResponse] {.async.} =
  ## Classifies one interaction and routes it through the shared response model.
  ##
  ## A ping bypasses every application handler but still flows through this one
  ## classifier, so both transports answer it identically. The returned
  ## `SelectedResponse.delivery` is `nil` only for a ping.
  dispatcher.requireOpen()
  case interaction.classify()
  of icPing:
    return pingResponse()
  of icCommand:
    return await dispatcher.commandRouterValue.selectResponse(
      interaction, receivedAt)
  of icComponent:
    if dispatcher.componentRouterValue.isNil:
      raise newException(InteractionDispatchError,
        "component interactions are not configured")
    return await dispatcher.componentRouterValue.selectResponse(
      interaction, dispatcher.routeClock(), receivedAt)
  of icModalSubmit:
    if dispatcher.modalRouterValue.isNil:
      raise newException(InteractionDispatchError,
        "modal interactions are not configured")
    return await dispatcher.modalRouterValue.selectResponse(
      interaction, dispatcher.routeClock(), receivedAt)
  of icAutocomplete:
    return await selectAutocompleteResponse(
      dispatcher.autocompleteRegistryValue, dispatcher.app.serviceRef,
      interaction, receivedAt, dispatcher.handlerFailureObserver)
  of icUnknown:
    raise newException(InteractionDispatchError,
      "unsupported interaction type")

proc callbackBytes(node: JsonNode): seq[byte] =
  let serialized = $node
  result = newSeq[byte](serialized.len)
  for index, value in serialized:
    result[index] = byte(ord(value))

proc asHttpHandler*[S](dispatcher: InteractionDispatcher[S]):
    InteractionHttpHandler =
  ## Adapts the dispatcher to verified HTTP ingress.
  ##
  ## The returned handler serializes the selected callback and hands
  ## `InteractionHttpServer` the delivery callbacks it invokes after its socket
  ## write, so the exchange is confirmed only once the write succeeds and marked
  ## unknown on a failed or cancelled write. Rejects a non-HTTP ingress app.
  if dispatcher.isNil or dispatcher.app.isNil or
      dispatcher.app.config.interactionIngress != ingressHttp:
    raise newException(ValueError,
      "HTTP interaction handler requires HTTP interaction ingress")
  result = proc(body: seq[byte], receivedAt: MonoMillis):
      Future[InteractionHttpResponse] {.gcsafe, raises: [].} =
    proc run(): Future[InteractionHttpResponse] {.async.} =
      var bodyText = newString(body.len)
      for index, value in body:
        bodyText[index] = char(value)
      let interaction = parseJson(bodyText)
      let selected = await dispatcher.dispatch(interaction, receivedAt)
      let bytes = selected.body.callbackBytes()
      if selected.delivery.isNil:
        # A ping carries no response authority; its delivery is unconditional.
        return jsonInteractionResponse(bytes)
      let delivery = selected.delivery
      proc confirmDelivery() {.closure, gcsafe, raises: [].} =
        delivery.confirmInitialDelivery()
      proc markDeliveryUnknown() {.closure, gcsafe, raises: [].} =
        delivery.markInitialDeliveryUnknown()
      return jsonInteractionResponse(
        bytes,
        deliveryConfirmed = confirmDelivery,
        deliveryUnknown = markDeliveryUnknown)
    {.cast(gcsafe).}:
      return run()

proc asGatewayHandler*[S](dispatcher: InteractionDispatcher[S]):
    proc(interaction: JsonNode, receivedAt: MonoMillis,
         sender: InitialResponseSender): Future[void]
      {.gcsafe, raises: [].} =
  ## Adapts the dispatcher to Gateway interaction ingress.
  ##
  ## The returned handler selects the same callback body as the HTTP adapter and
  ## sends it through `sender`; delivery is confirmed only after the callback
  ## REST request succeeds and marked unknown on failure or cancellation.
  ## Rejects a non-Gateway ingress app.
  if dispatcher.isNil or dispatcher.app.isNil or
      dispatcher.app.config.interactionIngress != ingressGateway:
    raise newException(ValueError,
      "Gateway interaction handler requires Gateway interaction ingress")
  result = proc(interaction: JsonNode, receivedAt: MonoMillis,
                sender: InitialResponseSender): Future[void]
      {.gcsafe, raises: [].} =
    proc run(): Future[void] {.async.} =
      if sender.isNil:
        raise newException(ValueError, "Gateway interaction sender is required")
      let selected = await dispatcher.dispatch(interaction, receivedAt)
      try:
        await sender(selected.body)
        if not selected.delivery.isNil:
          selected.delivery.confirmInitialDelivery()
      except CancelledError:
        if not selected.delivery.isNil:
          selected.delivery.markInitialDeliveryUnknown()
        raise
      except CatchableError:
        if not selected.delivery.isNil:
          selected.delivery.markInitialDeliveryUnknown()
        raise
    {.cast(gcsafe).}:
      return run()

proc closeOwned[S](dispatcher: InteractionDispatcher[S]): Future[void] {.
                   async: (raises: []).} =
  try:
    await dispatcher.commandRouterValue.close()
    if not dispatcher.componentRouterValue.isNil:
      await dispatcher.componentRouterValue.close()
    if not dispatcher.modalRouterValue.isNil:
      await dispatcher.modalRouterValue.close()
  finally:
    dispatcher.state = dsClosed

proc completedClose(): Future[void] {.raises: [].} =
  result = newFuture[void]("cordnim.interactions.dispatcher-closed")
  result.complete()

proc close*[S](dispatcher: InteractionDispatcher[S]): Future[void] =
  ## Cancels and joins every dispatcher-owned background task. Idempotent.
  ##
  ## This drains command auto-defer completions and all retained component and
  ## modal handler tails, so no future outlives the dispatcher.
  if dispatcher.isNil:
    return completedClose()
  if dispatcher.state == dsOpen:
    # Seal synchronous registration and new dispatch before the first await.
    # The stored close task, rather than any individual waiter, owns shutdown.
    dispatcher.state = dsClosing
    dispatcher.closeTask = dispatcher.closeOwned()
  noCancel(dispatcher.closeTask)
