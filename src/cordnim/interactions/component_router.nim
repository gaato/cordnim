## Stateless typed routing for persistent Discord message components.
##
## The router authenticates `custom_id` before selecting a route, decodes the
## versioned payload into its Nim action type, and invokes an ordinary Chronos
## handler. No process-local collector is needed, so registered buttons survive
## restarts as long as signing keys and migration decoders remain available.

import std/[json, tables]

import chronos

import cordnim/components/[routes, typed_routes]
import ./[context, router]

type
  ComponentRouteDispatchError* = object of CatchableError ## Malformed,
    ## unauthenticated, expired, or unregistered component route.

  ComponentResponseKind* = enum ## Initial callback produced by a typed
    ## component handler.
    crkMessage, ## Send a new interaction message (callback type 4).
    crkUpdateMessage, ## Update the component's source message (type 7).
    crkModal ## Present a modal (callback type 9).

  ComponentResponse* = object ## Transport-neutral immediate component response.
    kind*: ComponentResponseKind ## Discord callback semantic.
    data*: JsonNode ## Message or modal callback data.

  ComponentInvocation* = object ## Verified message-component interaction
    ## supplied to handlers.
    context*: InvocationContext ## Installation owner and effective permissions.
    componentType*: int ## Raw Discord component type number.
    values*: seq[string] ## Select values, empty for buttons.
    resolved*: JsonNode ## Lossless resolved entity maps.
    raw*: JsonNode ## Complete interaction for raw escape hatches.

  ComponentCtx*[S] = object ## Typed application services plus verified
    ## component invocation metadata.
    services*: S ## Application-owned dependency container.
    invocation*: ComponentInvocation ## Current component activation.

  ComponentHandler*[S, T] = proc(context: ComponentCtx[S], action: T):
    Future[ComponentResponse] {.closure, gcsafe, raises: [].} ## Handler for one
    ## decoded typed action.

  ErasedComponentHandler[S] = proc(services: S,
    invocation: ComponentInvocation, envelope: RouteEnvelope):
    Future[ComponentResponse] {.closure, gcsafe, raises: [].}

  ComponentRouter*[S] = ref object ## Typed persistent route registry using one
    ## shared HMAC key ring.
    services*: S ## Application-owned dependency container.
    envelope*: RouteCodec ## Shared HMAC verification and rotation config.
    handlers: Table[uint16, ErasedComponentHandler[S]]

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

proc showComponentModal*(data: sink JsonNode): ComponentResponse =
  ## Creates a modal response from `ModalSpec.toJson()` data.
  if data.isNil or data.kind != JObject:
    raise newException(ValueError, "modal response data must be an object")
  ComponentResponse(kind: crkModal, data: data)

proc callbackJson*(response: ComponentResponse): JsonNode =
  ## Serializes a component response as a Discord interaction callback.
  result = newJObject()
  result["type"] = %(case response.kind
    of crkMessage: 4
    of crkUpdateMessage: 7
    of crkModal: 9)
  result["data"] = if response.data.isNil:
    newJObject()
  else:
    response.data.copy()
  # Component callbacks inherit the library-wide safe mention default unless
  # the handler explicitly supplies a narrower Discord policy.
  if response.kind != crkModal and
      not result["data"].hasKey("allowed_mentions"):
    result["data"]["allowed_mentions"] = %*{"parse": []}

proc newComponentRouter*[S](services: sink S,
                            envelope: sink RouteCodec): ComponentRouter[S] =
  ## Creates an empty persistent router around one signing-key ring.
  if envelope.signer.isNil:
    raise newException(ValueError,
      "component router requires an HMAC signer")
  ComponentRouter[S](
    services: services,
    envelope: envelope,
    handlers: initTable[uint16, ErasedComponentHandler[S]]()
  )

proc register*[S, T](router: ComponentRouter[S], codec: TypedRouteCodec[T],
                     handler: ComponentHandler[S, T]) =
  ## Registers one stable route type and its typed migration decoders.
  if router.isNil:
    raise newException(ValueError, "component router is nil")
  if handler.isNil:
    raise newException(ValueError, "component route handler is nil")
  if codec.envelope.activeKeyId != router.envelope.activeKeyId or
      codec.envelope.keys != router.envelope.keys:
    raise newException(ValueError,
      "typed route codec does not use the component router key ring")
  if router.handlers.hasKey(codec.routeTypeId):
    raise newException(ValueError,
      "duplicate component route type ID " & $codec.routeTypeId)

  let typedCodec = codec
  let typedHandler = handler
  let erased: ErasedComponentHandler[S] = proc(
      services: S, invocation: ComponentInvocation,
      envelope: RouteEnvelope): Future[ComponentResponse]
      {.gcsafe, raises: [].} =
    proc dispatch(): Future[ComponentResponse] {.
        async: (raises: [CancelledError, ComponentRouteDispatchError]).} =
      let decoded = typedCodec.decodeVerified(envelope)
      if not decoded.ok:
        raise newException(ComponentRouteDispatchError,
          "component route payload could not be decoded")
      try:
        return await typedHandler(
          ComponentCtx[S](services: services, invocation: invocation),
          decoded.value
        )
      except CancelledError:
        raise
      except CatchableError:
        # Keep application exception details out of protocol-facing failures;
        # logging adapters can record them at the handler boundary instead.
        raise newException(ComponentRouteDispatchError,
          "component route handler failed")
    {.cast(gcsafe).}:
      return dispatch()
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
  result.raw = interaction
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

proc route*[S](router: ComponentRouter[S], interaction: JsonNode,
               nowUnixSeconds: int64): Future[JsonNode] {.async.} =
  ## Authenticates, decodes, dispatches, and serializes one component callback.
  if router.isNil:
    raise newException(ValueError, "component router is nil")
  let invocation = interaction.decodeInvocation()
  let data = interaction["data"]
  if not data.hasKey("custom_id") or data["custom_id"].kind != JString:
    raise newException(ComponentRouteDispatchError,
      "component custom_id is missing")
  let decoded = router.envelope.decodeRoute(
    data["custom_id"].getStr(), nowUnixSeconds)
  if not decoded.ok:
    raise newException(ComponentRouteDispatchError,
      "component custom_id authentication failed")
  if not router.handlers.hasKey(decoded.envelope.routeTypeId):
    raise newException(ComponentRouteDispatchError,
      "component route type is not registered")
  let response = await router.handlers[decoded.envelope.routeTypeId](
    router.services, invocation, decoded.envelope)
  response.callbackJson()
