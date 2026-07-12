import std/[atomics, json, options, strutils, unittest]

import chronos

import cordnim/[app, commands, components, interactions]
import cordnim/core/ids
import cordnim/rest/chronos_driver

type
  DispatcherServices = object
    greeting: string

  ButtonAction = object
    id: uint16

  ModalState = object
    id: uint16

  NoteModal {.discordModal(title = "Note", customId = "note_modal").} = object
    note {.textInput(label = "Note", minLength = 1, maxLength = 50).}: string

deriveDiscordModal(NoteModal)

proc greet(ctx: CommandCtx[DispatcherServices], name: string):
    Future[CommandResult]
    {.async, discordCommand(name = "greet", description = "Greet").} =
  return succeeded(ctx.services.greeting & name)

proc boom(ctx: CommandCtx[DispatcherServices]):
    Future[CommandResult]
    {.async, discordCommand(name = "boom", description = "Fail").} =
  discard ctx
  raise newException(ValueError, "SECRET-command-handler-detail")

proc signer(key, message: openArray[byte]): array[32, byte]
    {.gcsafe, raises: [].} =
  for index, value in key:
    result[index mod result.len] = result[index mod result.len] xor value
  for index, value in message:
    result[index mod result.len] = result[index mod result.len] xor value

func sharedEnvelope(): RouteCodec =
  RouteCodec(
    activeKeyId: 1,
    keys: @[RouteSigningKey(id: 1, material: @[byte 7, 7, 7])],
    signer: signer)

proc encodeButton(value: ButtonAction): seq[byte] {.gcsafe, raises: [].} =
  @[byte(value.id shr 8), byte(value.id)]

proc decodeButton(payload: openArray[byte]): ButtonAction
    {.gcsafe, raises: [ValueError].} =
  if payload.len != 2: raise newException(ValueError, "bad button")
  ButtonAction(id: uint16(payload[0]) shl 8 or uint16(payload[1]))

proc encodeState(value: ModalState): seq[byte] {.gcsafe, raises: [].} =
  @[byte(value.id shr 8), byte(value.id)]

proc decodeState(payload: openArray[byte]): ModalState
    {.gcsafe, raises: [ValueError].} =
  if payload.len != 2: raise newException(ValueError, "bad state")
  ModalState(id: uint16(payload[0]) shl 8 or uint16(payload[1]))

func buttonCodec(): TypedRouteCodec[ButtonAction] =
  TypedRouteCodec[ButtonAction](
    envelope: sharedEnvelope(), routeTypeId: 10, activeVersion: 1,
    encodePayload: encodeButton,
    decoders: @[VersionedRouteDecoder[ButtonAction](
      version: 1, decode: decodeButton)])

func modalCodec(): TypedRouteCodec[ModalState] =
  TypedRouteCodec[ModalState](
    envelope: sharedEnvelope(), routeTypeId: 20, activeVersion: 1,
    encodePayload: encodeState,
    decoders: @[VersionedRouteDecoder[ModalState](
      version: 1, decode: decodeState)])

proc handleButton(ctx: ComponentCtx[DispatcherServices], action: ButtonAction):
    Future[ComponentResponse] {.async.} =
  discard ctx
  return updateComponent(%*{"content": "button:" & $action.id})

proc handleSlowButton(ctx: ComponentCtx[DispatcherServices],
                      action: ButtonAction): Future[ComponentResponse] {.
                      async.} =
  discard action
  await ctx.deferUpdate()
  await sleepAsync(30.seconds)
  return respondedViaContext()

proc noteDecoder(data: JsonNode, hooks: ModalDecodeHooks):
    ModalDecodeResult[NoteModal] {.gcsafe, raises: [CatchableError].} =
  decodeDiscordModal(NoteModal, data, hooks)

proc handleModal(ctx: ModalCtx[DispatcherServices], state: ModalState,
                 form: ModalDecodeResult[NoteModal]):
    Future[ComponentResponse] {.async.} =
  discard ctx
  if not form.ok:
    return replyComponent(%*{"content": "invalid"})
  return replyComponent(%*{"content":
    "modal:" & $state.id & ":" & form.value.note})

proc suggest(services: ref DispatcherServices, request: AutocompleteRequest):
    Future[seq[AutocompleteChoice]] {.async.} =
  discard services
  discard request
  return @[initAutocompleteChoice("Nim", "nim")]

proc integerChoiceForString(services: ref DispatcherServices,
                            request: AutocompleteRequest):
    Future[seq[AutocompleteChoice]] {.async.} =
  discard services
  discard request
  # An integer choice for a STRING-focused option: a kind mismatch.
  return @[initAutocompleteChoice("five", 5'i64)]

proc newDispatcher(ingress: InteractionIngress;
                   routeClock: InteractionWallClock =
                     systemInteractionUnixSeconds):
    (DiscordApp[DispatcherServices], InteractionDispatcher[DispatcherServices]) =
  let application = newDiscordApp(
    DispatcherServices(greeting: "Hello "), initAppConfig(ingress),
    commandSet(greet))
  let dispatcher = newInteractionDispatcher(
    application, routeEnvelope = some(sharedEnvelope()),
    routeClock = routeClock)
  dispatcher.registerComponent(buttonCodec(), handleButton)
  dispatcher.registerModal(modalCodec(), noteDecoder, handleModal)
  dispatcher.registerAutocomplete(
    initCommandKey(ckChatInput, "greet"), "name", suggest)
  (application, dispatcher)

proc jsonBytes(node: JsonNode): seq[byte] =
  let text = $node
  result = newSeq[byte](text.len)
  for index, value in text:
    result[index] = byte(ord(value))

proc bodyText(response: InteractionHttpResponse): JsonNode =
  var text = newString(response.body.len)
  for index, value in response.body:
    text[index] = char(value)
  parseJson(text)

proc commandPayload(): JsonNode =
  %*{
    "id": "100", "application_id": "200", "type": 2, "token": "tkn",
    "context": 0, "guild_id": "300",
    "authorizing_integration_owners": {"0": "300"},
    "user": {"id": "42"},
    "data": {"name": "greet", "type": 1,
      "options": [{"name": "name", "type": 3, "value": "Nim"}]}
  }

proc boomPayload(): JsonNode =
  result = commandPayload()
  result["data"] = %*{"name": "boom", "type": 1, "options": []}

proc newBoomDispatcher(ingress: InteractionIngress;
                       observer: DeferredFailureObserver):
    (DiscordApp[DispatcherServices], InteractionDispatcher[DispatcherServices]) =
  let application = newDiscordApp(
    DispatcherServices(greeting: "Hello "), initAppConfig(ingress),
    commandSet(greet, boom))
  let dispatcher = newInteractionDispatcher(
    application, commandFailureObserver = observer)
  (application, dispatcher)

suite "unified interaction dispatcher":
  test "HTTP and Gateway select the identical command callback body":
    proc scenario(): Future[(JsonNode, JsonNode)] {.async.} =
      let (httpApp, httpDispatcher) = newDispatcher(ingressHttp)
      let httpResponse = await httpDispatcher.asHttpHandler()(
        commandPayload().jsonBytes(), monotonicMillis())
      await httpDispatcher.close()

      let (gatewayApp, gatewayDispatcher) = newDispatcher(ingressGateway)
      var captured: JsonNode
      proc sender(response: JsonNode): Future[void] {.gcsafe, raises: [].} =
        captured = response
        result = newFuture[void]("test.gateway.sender")
        result.complete()
      await gatewayDispatcher.asGatewayHandler()(
        commandPayload(), monotonicMillis(), sender)
      await gatewayDispatcher.close()
      discard httpApp
      discard gatewayApp
      return (httpResponse.bodyText(), captured)

    let (httpBody, gatewayBody) = waitFor scenario()
    check httpBody["type"].getInt() == 4
    check httpBody["data"]["content"].getStr() == "Hello Nim"
    check httpBody == gatewayBody

  test "PING bypasses handlers through the shared classifier":
    proc scenario(): Future[InteractionHttpResponse] {.async.} =
      let (app, dispatcher) = newDispatcher(ingressHttp)
      let handler = dispatcher.asHttpHandler()
      result = await handler(
        jsonBytes(%*{"type": 1}), monotonicMillis())
      await dispatcher.close()
      discard app

    let response = waitFor scenario()
    check response.bodyText()["type"].getInt() == 1
    # A ping carries no delivery authority.
    check response.deliveryConfirmed.isNil

  test "routes a component activation to its typed handler":
    proc scenario(): Future[JsonNode] {.async.} =
      let (app, dispatcher) = newDispatcher(ingressHttp)
      let customId = buttonCodec().encode(ButtonAction(id: 3), 9999999999'i64)
      let payload = %*{
        "id": "101", "type": 3, "context": 0, "guild_id": "300",
        "authorizing_integration_owners": {"0": "300"},
        "user": {"id": "42"},
        "data": {"component_type": 2, "custom_id": customId}}
      let response = await dispatcher.asHttpHandler()(
        payload.jsonBytes(), monotonicMillis())
      await dispatcher.close()
      discard app
      return response.bodyText()

    let body = waitFor scenario()
    check body["type"].getInt() == 7
    check body["data"]["content"].getStr() == "button:3"

  test "persistent route expiry uses the injected wall clock":
    proc scenario(): Future[JsonNode] {.async.} =
      let now = new(int64)
      now[] = 1_000
      let clock: InteractionWallClock = proc(): int64 {.
          gcsafe, raises: [].} = now[]
      let (app, dispatcher) = newDispatcher(ingressHttp, clock)
      let customId = buttonCodec().encode(ButtonAction(id: 4), 1_001)
      let payload = %*{
        "id": "104", "type": 3, "context": 0, "guild_id": "300",
        "authorizing_integration_owners": {"0": "300"},
        "user": {"id": "42"},
        "data": {"component_type": 2, "custom_id": customId}}
      let response = await dispatcher.asHttpHandler()(
        payload.jsonBytes(), monotonicMillis())
      await dispatcher.close()
      discard app
      return response.bodyText()

    let body = waitFor scenario()
    check body["type"].getInt() == 7
    check body["data"]["content"].getStr() == "button:4"

  test "routes a modal submission to its typed handler":
    proc scenario(): Future[JsonNode] {.async.} =
      let (app, dispatcher) = newDispatcher(ingressHttp)
      let customId = modalCodec().encode(ModalState(id: 8), 9999999999'i64)
      let payload = %*{
        "id": "102", "type": 5, "context": 0, "guild_id": "300",
        "authorizing_integration_owners": {"0": "300"},
        "user": {"id": "42"},
        "data": {"custom_id": customId, "components": [
          {"type": 18, "component": {
            "type": 4, "custom_id": "note", "value": "hi"}}]}}
      let response = await dispatcher.asHttpHandler()(
        payload.jsonBytes(), monotonicMillis())
      await dispatcher.close()
      discard app
      return response.bodyText()

    let body = waitFor scenario()
    check body["type"].getInt() == 4
    check body["data"]["content"].getStr() == "modal:8:hi"

  test "routes an autocomplete request to a type-8 callback":
    proc scenario(): Future[JsonNode] {.async.} =
      let (app, dispatcher) = newDispatcher(ingressHttp)
      let payload = %*{
        "id": "103", "type": 4, "context": 0, "guild_id": "300",
        "authorizing_integration_owners": {"0": "300"},
        "user": {"id": "42"}, "locale": "en-US",
        "data": {"name": "greet", "type": 1, "options": [
          {"name": "name", "type": 3, "value": "n", "focused": true}]}}
      let response = await dispatcher.asHttpHandler()(
        payload.jsonBytes(), monotonicMillis())
      await dispatcher.close()
      discard app
      return response.bodyText()

    let body = waitFor scenario()
    check body["type"].getInt() == 8
    check body["data"]["choices"][0]["value"].getStr() == "nim"

  test "rejects an adapter that does not match the app ingress":
    let (httpApp, httpDispatcher) = newDispatcher(ingressHttp)
    expect ValueError:
      discard httpDispatcher.asGatewayHandler()
    waitFor httpDispatcher.close()
    discard httpApp

    let (gatewayApp, gatewayDispatcher) = newDispatcher(ingressGateway)
    expect ValueError:
      discard gatewayDispatcher.asHttpHandler()
    waitFor gatewayDispatcher.close()
    discard gatewayApp

  test "an unsupported interaction type fails through dispatch":
    proc scenario(): Future[bool] {.async.} =
      let (app, dispatcher) = newDispatcher(ingressHttp)
      try:
        discard await dispatcher.dispatch(
          %*{"id": "1", "type": 99}, monotonicMillis())
        return false
      except InteractionDispatchError:
        await dispatcher.close()
        discard app
        return true

    check waitFor scenario()

  test "close is idempotent":
    proc scenario(): Future[void] {.async.} =
      let (app, dispatcher) = newDispatcher(ingressHttp)
      await dispatcher.close()
      await dispatcher.close()
      discard app

    waitFor scenario()

  test "close seals registration and dispatch":
    proc scenario(): Future[bool] {.async.} =
      let (app, dispatcher) = newDispatcher(ingressHttp)
      await dispatcher.close()
      var dispatchRejected = false
      try:
        discard await dispatcher.dispatch(
          commandPayload(), monotonicMillis())
      except InteractionDispatcherClosedError:
        dispatchRejected = true

      var registrationRejected = false
      try:
        dispatcher.registerAutocomplete(
          initCommandKey(ckChatInput, "other"), "value", suggest)
      except InteractionDispatcherClosedError:
        registrationRejected = true
      discard app
      return dispatchRejected and registrationRejected

    check waitFor scenario()

  test "close concurrent with a retained handler preserves delivery authority":
    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        DispatcherServices(), initAppConfig(ingressHttp), commandSet(greet))
      let dispatcher = newInteractionDispatcher(
        application, routeEnvelope = some(sharedEnvelope()))
      dispatcher.registerComponent(buttonCodec(), handleSlowButton)
      let customId = buttonCodec().encode(
        ButtonAction(id: 5), 9_999_999_999'i64)
      let payload = %*{
        "id": "105", "type": 3, "context": 0, "guild_id": "300",
        "authorizing_integration_owners": {"0": "300"},
        "user": {"id": "42"},
        "data": {"component_type": 2, "custom_id": customId}}
      let selected = await dispatcher.dispatch(payload, monotonicMillis())
      doAssert selected.body["type"].getInt() == 6
      await dispatcher.close()
      selected.delivery.confirmInitialDelivery()
      discard application
      return selected.body

    check waitFor(scenario())["type"].getInt() == 6

  test "HTTP command handler failure is redacted, observing phase and ID only":
    var sawHandlerPhase: Atomic[bool]
    var sawId: Atomic[bool]
    sawHandlerPhase.store(false)
    sawId.store(false)
    proc observer(kind: DeferredFailureKind, id: Option[InteractionId])
        {.gcsafe, raises: [].} =
      if kind == dfkHandler:
        sawHandlerPhase.store(true)
      if id.isSome and $id.get() == "100":
        sawId.store(true)

    proc scenario(): Future[string] {.async.} =
      let (app, dispatcher) = newBoomDispatcher(ingressHttp, observer)
      var message = "no error"
      try:
        discard await dispatcher.asHttpHandler()(
          boomPayload().jsonBytes(), monotonicMillis())
      except CommandApplicationError as error:
        message = error.msg
      await dispatcher.close()
      discard app
      return message

    let message = waitFor scenario()
    check not message.contains("SECRET")
    check message == "command application failed before acknowledgement"
    check sawHandlerPhase.load()
    check sawId.load()

  test "Gateway command handler failure is redacted before the sender runs":
    var sawHandlerPhase: Atomic[bool]
    var senderCalled: Atomic[bool]
    sawHandlerPhase.store(false)
    senderCalled.store(false)
    proc observer(kind: DeferredFailureKind, id: Option[InteractionId])
        {.gcsafe, raises: [].} =
      discard id
      if kind == dfkHandler:
        sawHandlerPhase.store(true)

    proc scenario(): Future[string] {.async.} =
      let (app, dispatcher) = newBoomDispatcher(ingressGateway, observer)
      proc sender(response: JsonNode): Future[void] {.gcsafe, raises: [].} =
        discard response
        senderCalled.store(true)
        result = newFuture[void]("test.gateway.sender")
        result.complete()
      var message = "no error"
      try:
        await dispatcher.asGatewayHandler()(
          boomPayload(), monotonicMillis(), sender)
      except CommandApplicationError as error:
        message = error.msg
      await dispatcher.close()
      discard app
      return message

    let message = waitFor scenario()
    check not message.contains("SECRET")
    check message == "command application failed before acknowledgement"
    check sawHandlerPhase.load()
    check not senderCalled.load()          # failure is raised before the sender

  test "an autocomplete choice-kind mismatch fails with no callback":
    proc scenario(): Future[string] {.async.} =
      let application = newDiscordApp(
        DispatcherServices(greeting: "Hello "), initAppConfig(ingressHttp),
        commandSet(greet))
      let dispatcher = newInteractionDispatcher(application)
      # `greet` declares `name` as a STRING option; the handler returns an
      # integer choice, so the request-aware builder must reject it.
      dispatcher.registerAutocomplete(
        initCommandKey(ckChatInput, "greet"), "name", integerChoiceForString)
      let payload = %*{
        "id": "108", "type": 4, "context": 0, "guild_id": "300",
        "authorizing_integration_owners": {"0": "300"},
        "user": {"id": "42"}, "locale": "en-US",
        "data": {"name": "greet", "type": 1, "options": [
          {"name": "name", "type": 3, "value": "n", "focused": true}]}}
      var message = "no error"
      var callbackSelected = false
      try:
        let selected = await dispatcher.dispatch(payload, monotonicMillis())
        callbackSelected = not selected.body.isNil
      except AutocompleteDispatchError as error:
        message = error.msg
      await dispatcher.close()
      discard application
      doAssert not callbackSelected          # no type-8 callback was produced
      return message

    check waitFor(scenario()) ==
      "autocomplete response could not be selected"
