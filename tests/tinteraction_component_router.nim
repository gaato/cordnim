import std/[atomics, json, options, strutils, unittest]

import chronos

import cordnim/[components, interactions]
import cordnim/core/ids
import cordnim/rest/chronos_driver

type
  Services = object
    prefix: string

  DeployAction = object
    buildId: uint16

proc signer(key, message: openArray[byte]): array[32, byte]
    {.gcsafe, raises: [].} =
  for index, value in key:
    result[index mod result.len] = result[index mod result.len] xor value
  for index, value in message:
    result[index mod result.len] = result[index mod result.len] xor value

proc encodeAction(value: DeployAction): seq[byte]
    {.gcsafe, raises: [].} =
  @[byte(value.buildId shr 8), byte(value.buildId)]

proc decodeAction(payload: openArray[byte]): DeployAction
    {.gcsafe, raises: [ValueError].} =
  if payload.len != 2:
    raise newException(ValueError, "wrong action length")
  DeployAction(buildId: uint16(payload[0]) shl 8 or uint16(payload[1]))

func routeCodec(typeId: uint16 = 10): TypedRouteCodec[DeployAction] =
  let envelope = RouteCodec(
    activeKeyId: 1,
    keys: @[RouteSigningKey(id: 1, material: @[byte 3, 4, 5])],
    signer: signer
  )
  TypedRouteCodec[DeployAction](
    envelope: envelope,
    routeTypeId: typeId,
    activeVersion: 2,
    encodePayload: encodeAction,
    decoders: @[
      VersionedRouteDecoder[DeployAction](version: 1, decode: decodeAction),
      VersionedRouteDecoder[DeployAction](version: 2, decode: decodeAction)
    ]
  )

proc svc(prefix = ""): ref Services =
  new result
  result.prefix = prefix

proc interaction(customId: string): JsonNode =
  %*{
    "id": "100",
    "type": 3,
    "context": 1,
    "user": {"id": "42"},
    "data": {
      "component_type": 2,
      "custom_id": customId
    }
  }

proc handleDeploy(context: ComponentCtx[Services], action: DeployAction):
    Future[ComponentResponse] {.async.} =
  return updateComponent(%*{
    "content": context.services.prefix & $action.buildId
  })

proc handleReply(context: ComponentCtx[Services], action: DeployAction):
    Future[ComponentResponse] {.async.} =
  await context.reply(%*{"content": "reply:" & $action.buildId})
  return respondedViaContext()

proc handleDeferEdit(context: ComponentCtx[Services], action: DeployAction):
    Future[ComponentResponse] {.async.} =
  await context.deferUpdate()
  await context.editOriginal(%*{"content": "edited:" & $action.buildId})
  return respondedViaContext()

proc handleBoom(context: ComponentCtx[Services], action: DeployAction):
    Future[ComponentResponse] {.async.} =
  discard context
  discard action
  raise newException(ValueError, "SECRET-must-stay-redacted")

proc sampleModal(): ModalSpec =
  initModalSpec("deploy_modal", "Deploy", [
    modalTextDisplay("Confirm deployment")
  ])

proc handleModal(context: ComponentCtx[Services], action: DeployAction):
    Future[ComponentResponse] {.async.} =
  discard action
  await context.showModal(sampleModal())
  return respondedViaContext()

suite "persistent component router":
  test "authenticates and dispatches typed state after a restart":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = routeCodec()
      let customId = codec.encode(DeployAction(buildId: 9001), 2_000)
      let router = newComponentRouter(svc("build:"), codec.envelope)
      router.register(codec, handleDeploy)
      result = await router.route(interaction(customId), 1_000)
      await router.close()

    let response = waitFor scenario()
    check response["type"].getInt() == 7
    check response["data"]["content"].getStr() == "build:9001"
    check response["data"]["allowed_mentions"]["parse"].len == 0

  test "holds application services by reference, never by copy":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = routeCodec()
      let customId = codec.encode(DeployAction(buildId: 1), 2_000)
      let services = svc("first:")
      let router = newComponentRouter(services, codec.envelope)
      router.register(codec, handleDeploy)
      # A mutation after construction must be visible to the handler.
      services.prefix = "second:"
      result = await router.route(interaction(customId), 1_000)
      await router.close()

    check waitFor(scenario())["data"]["content"].getStr() == "second:1"

  test "rejects tampering before invoking a route handler":
    proc scenario(): Future[bool] {.async.} =
      let codec = routeCodec()
      var customId = codec.encode(DeployAction(buildId: 7), 2_000)
      customId[^1] = if customId[^1] == 'A': 'B' else: 'A'
      let router = newComponentRouter(svc(), codec.envelope)
      router.register(codec, handleDeploy)
      try:
        discard await router.route(interaction(customId), 1_000)
        return false
      except ComponentRouteDispatchError:
        await router.close()
        return true

    check waitFor scenario()

  test "selects an immediate reply through the response context":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = routeCodec(11)
      let customId = codec.encode(DeployAction(buildId: 5), 2_000)
      let router = newComponentRouter(svc(), codec.envelope)
      router.register(codec, handleReply)
      result = await router.route(interaction(customId), 1_000)
      await router.close()

    let response = waitFor scenario()
    check response["type"].getInt() == 4
    check response["data"]["content"].getStr() == "reply:5"
    check response["data"]["allowed_mentions"]["parse"].len == 0

  test "deferred update edits only after confirmed delivery":
    var edits: Atomic[int]
    edits.store(0)
    proc postAck(interaction: JsonNode, response: ContextResponse):
        Future[void] {.gcsafe, raises: [].} =
      doAssert interaction{"id"}.getStr() == "100"
      doAssert response.action == raEditOriginal
      doAssert response.body{"content"}.getStr() == "edited:8"
      edits.store(edits.load() + 1)
      result = newFuture[void]("test.component.postack")
      result.complete()

    proc scenario(): Future[JsonNode] {.async.} =
      let codec = routeCodec(12)
      let customId = codec.encode(DeployAction(buildId: 8), 2_000)
      let router = newComponentRouter(svc(), codec.envelope, postAck)
      router.register(codec, handleDeferEdit)
      let selected = await router.selectResponse(
        interaction(customId), 1_000, monotonicMillis())
      doAssert edits.load() == 0
      selected.delivery.confirmInitialDelivery()
      await sleepAsync(10.milliseconds)
      doAssert edits.load() == 1
      await router.close()
      return selected.body

    let body = waitFor scenario()
    check body["type"].getInt() == 6
    check not body.hasKey("data")

  test "application exceptions are redacted at the dispatch boundary":
    proc scenario(): Future[string] {.async.} =
      let codec = routeCodec(13)
      let customId = codec.encode(DeployAction(buildId: 3), 2_000)
      let router = newComponentRouter(svc(), codec.envelope)
      router.register(codec, handleBoom)
      try:
        discard await router.route(interaction(customId), 1_000)
        return "no error"
      except ComponentRouteDispatchError as error:
        await router.close()
        return error.msg

    let message = waitFor scenario()
    check not message.contains("SECRET")
    check message.contains("component route handler failed")

  test "retained post-ack failures reach the redacted observer only":
    var observed: Atomic[int]
    observed.store(0)
    proc failingPostAck(interaction: JsonNode, response: ContextResponse):
        Future[void] {.gcsafe, raises: [].} =
      discard interaction
      discard response
      result = newFuture[void]("test.component.failing-postack")
      result.fail(newException(ValueError, "SECRET transport detail"))
    proc observer(interactionId: Option[InteractionId])
        {.gcsafe, raises: [].} =
      if interactionId.isSome and $interactionId.get() == "100":
        observed.store(1)

    proc scenario(): Future[void] {.async.} =
      let codec = routeCodec(14)
      let customId = codec.encode(DeployAction(buildId: 8), 2_000)
      let router = newComponentRouter(
        svc(), codec.envelope, failingPostAck, observer)
      router.register(codec, handleDeferEdit)
      let selected = await router.selectResponse(
        interaction(customId), 1_000, monotonicMillis())
      selected.delivery.confirmInitialDelivery()
      await sleepAsync(10.milliseconds)
      await router.close()

    waitFor scenario()
    check observed.load() == 1

  test "closing a retained waiter cannot cancel later delivery confirmation":
    proc scenario(): Future[void] {.async.} =
      let codec = routeCodec(15)
      let customId = codec.encode(DeployAction(buildId: 8), 2_000)
      let router = newComponentRouter(svc(), codec.envelope)
      router.register(codec, handleDeferEdit)
      let selected = await router.selectResponse(
        interaction(customId), 1_000, monotonicMillis())
      doAssert selected.body["type"].getInt() == 6
      await router.close()
      # close cancelled the retained edit waiter. Its cancellation must not
      # propagate into the exchange-owned delivery receipt.
      selected.delivery.confirmInitialDelivery()

    waitFor scenario()

  test "ModalSpec is the validated standard show-modal path":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = routeCodec(16)
      let customId = codec.encode(DeployAction(buildId: 1), 2_000)
      let router = newComponentRouter(svc(), codec.envelope)
      router.register(codec, handleModal)
      result = await router.route(interaction(customId), 1_000)
      await router.close()

    let response = waitFor scenario()
    check response["type"].getInt() == 9
    check response["data"]["custom_id"].getStr() == "deploy_modal"

    expect ValueError:
      discard showComponentModal(initModalSpec("bad", "", []))
    check showRawComponentModal(%*{
      "custom_id": "raw", "title": "Raw", "components": []
    }).kind == crkModal

  test "duplicate route registrations fail explicitly":
    let codec = routeCodec()
    let router = newComponentRouter(svc(), codec.envelope)
    router.register(codec, handleDeploy)
    expect ValueError:
      router.register(codec, handleDeploy)
    waitFor router.close()

  test "unregistered route types fail explicitly":
    proc scenario(): Future[bool] {.async.} =
      let registered = routeCodec(10)
      let foreign = routeCodec(99)
      let customId = foreign.encode(DeployAction(buildId: 1), 2_000)
      let router = newComponentRouter(svc(), registered.envelope)
      router.register(registered, handleDeploy)
      try:
        discard await router.route(interaction(customId), 1_000)
        return false
      except ComponentRouteDispatchError:
        await router.close()
        return true

    check waitFor scenario()
